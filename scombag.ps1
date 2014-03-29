param (
    [switch]$help = $false,
    [switch]$validate_map = $false,
    [switch]$enable_tracing = $false,
    [switch]$logic_debugging = $false,
    [string]$trace_guid = ""
)

Set-StrictMode -Version 3.0

function process_alerts([PSCustomObject]$objMapConfig, [String]$strExecutingPath, [String]$strTraceGuid) {
    $bSendPassFail = $false
    $strTrackFilePath = $strExecutingPath + $aryMainConf['track']['trk_file']
    $dtCurrentDate = [DateTime]::Now
    $objNewMappedScomAlerts = [PSCustomOBject]@{"actives" = @(); "passives" = @()}
    $aryAlertsToSkip = @()
    $aryMappedActivesToProcess = @{}

    if ($aryMainConf['main']['trace_mode_enabled'] -eq 0) {
        $objMappedScomAlerts = import_json_config($strTrackFilePath)

        foreach ($objMappedScomAlert in $objMappedScomAlerts.actives) {
            $dtModifiedDate = Get-Date $objMappedScomAlert.date_modified
            $dtDateDiff = $dtCurrentDate - $dtModifiedDate

            if (($objMappedScomAlert.archived -ieq "true") -and ($dtDateDiff.TotalDays -ge $aryMainConf['track']['trk_archive_days_ttl'])) {
                logger("Archived alert has aged out, removing " + $objMappedScomAlert.guid)
                continue
            } elseif ($dtDateDiff.TotalDays -ge $aryMainConf['track']['trk_alert_max_ttl']) {
                logger("Alert has reached max TTL, removing " + $objMappedScomAlert.guid)
                continue
            } elseif ($objMappedScomAlert.archived -ieq "false") {
                $objOpenScomAlert = Get-SCOMAlert -Id $objMappedScomAlert.guid
                $aryNagVars = @{"hostname" = $objMappedScomAlert.hostname; 
                                "service" = $objMappedScomAlert.service; 
                                "state" = "0"; 
                                "output" = ""; 
                                "activecheck" = "1";
                                "nrdpurl" = $objMappedScomAlert.nrdpurl;
                                "nrdptoken" = $objMappedScomAlert.nrdptoken}

                if ($objOpenScomAlert) {
                    if ($objOpenScomAlert.ResolutionState -eq 255) {
                        Logger("Alert for ID " + $objMappedScomAlert.guid + " is now OK! Archiving alert.")
                        $aryNagVars['output'] = "Alert for ID: " + $objMappedScomAlert.guid + " is now OK"
                    } elseif ($dtDateDiff.TotalHours -lt $aryMainConf['track']['trk_resend_alert']) {
                        Logger("Alert for ID " + $objMappedScomAlert.guid + " is within resend timer, ignoring this run.")
                        $aryAlertsToSkip += $objMappedScomAlert.guid
                        $objNewMappedScomAlerts.actives += $objMappedScomAlert
                        continue
                    } else {
                        $objNewMappedScomAlerts.actives += $objMappedScomAlert
                        $aryMappedActivesToProcess[$objMappedScomAlert.guid] = $objNewMappedScomAlerts.actives.Length - 1
                        continue
                    }
                } else {
                    Logger("Alert for ID: " + $objMappedScomAlert.guid + " no longer exists! Archiving alert.")
                    $aryNagVars['output'] = "Alert for ID " + $objMappedScomAlert.guid + " no longer exists! Closing Alert."
                }

                $xmlBuilder = generate_alert_xml($aryNagVars)
                $bSendSuccessful = send_alert_to_nagios $xmlBuilder $aryNagVars

                if ($bSendSuccessful) {
                    $objMappedScomAlert.archived = "true"
                    $objMappedScomAlert.date_modified = $dtCurrentDate.Ticks
                    $objMappedScomAlert.date_modified_friendly = $dtCurrentDate.DateTime
                }

                $objNewMappedScomAlerts.actives += $objMappedScomAlert
            } else {
                $objNewMappedScomAlerts.actives += $objMappedScomAlert
            }
        }

        foreach ($objMappedScomAlert in $objMappedScomAlerts.passives) {
            $dtModifiedDate = Get-Date $objMappedScomAlert.date_modified
            $dtDateDiff = $dtCurrentDate - $dtModifiedDate

            if ($dtDateDiff -ge $aryMainConf['track']['trk_archive_days_ttl']) {
                logger("Archived alert has aged out, removing " + $objMappedScomAlert.guid)
                continue
            } else {
                $objNewMappedScomAlerts.passives += $objMappedScomAlert
            }
        }

        $jsonMappedScomAlerts = $objNewMappedScomAlerts | ConvertTo-Json
        Set-Content $strTrackFilePath $jsonMappedScomAlerts
    }

    if (($aryMainConf['main']['trace_mode_enabled'] -eq 0) -or (($aryMainConf['main']['trace_mode_enabled'] -eq 1) -and ([String]::IsNullOrEmpty($strTraceGuid)))) {
        $objNewScomAlerts = Get-SCOMAlert -Criteria "ResolutionState = '0'"
    } elseif (($aryMainConf['main']['trace_mode_enabled'] -eq 1) -and ($strTraceGuid)) {
        $objNewScomAlerts = Get-SCOMAlert -Id $strTraceGuid
    } else {
        logger("Unable to determine operation mode. Cannot continue.")
        exit 2
    }

    foreach ($objNewAlert in $objNewScomAlerts) {
        $aryNagVars = @{"hostname" = ""; "service" = ""; "state" = ""; "output" = ""; "activecheck" = ""; "nrdpurl" = ""; "nrdptoken" = ""; "drop" = $false}
        if ($aryAlertsToSkip -contains $objNewAlert.Id) {
            continue
        }

        $objMapRoot = $objMapConfig.map.psobject.Get_properties()
        logger("Processing SCOM UID: " + $objNewAlert.Id)
        foreach ($objMapKvp in $objMapRoot) {
            scombag_assignment_eval $objMapKvp.name $objMapKvp.value $objNewAlert $objMapConfig $aryNagVars
        }

        $objLogicMapRoot = $objMapConfig.logicmap.psobject.Get_properties()
        foreach ($objLogicMapObject in $objLogicMapRoot) {
            $strDefaultParent = "none"

            if ($aryMainConf['main']['trace_logic_debug_enabled'] -eq 1) {
                logger("#################")
                logger("BEGIN ELEMENT: " + $objLogicMapObject.name)
                logger("#################")
            }

            $bReturn = scombag_logic_proc $objMapConfig.logicmap.($objLogicMapObject.name) $objNewAlert $objMapConfig $aryNagVars $strDefaultParent

            if ($bReturn) {
                foreach ($objReturnVals in $objMapConfig.logicmap.($objLogicMapObject.name).return.psobject.Get_Properties()) {
                    scombag_assignment_eval $objReturnVals.name $objReturnVals.value $objNewAlert $objMapConfig $aryNagVars
                }
            } 

            if ($aryMainConf['main']['trace_logic_debug_enabled'] -eq 1) {
                logger("#################")
                logger("END ELEMENT: " + $objLogicMapObject.name)
                logger("#################")
                logger("")
            }
        }

        if ($aryNagVars['drop']) {
            continue
        }

        $intLoops = 0
        $intMaxLoops = 8
        $bNext = $false
        do {
            $strUnsetVar = 0
            $aryNagVars.GetEnumerator() | % {
                if ($_.Value -Match "^\s*$") {
                    logger("Unset Key: " + $_.Key)
                    $strUnsetVar = $_.Key
                }
            }
            
            if ($strUnsetVar) {
                foreach ($objDefaults in $objMapConfig.default.$strUnsetVar.psobject.Get_properties()) {
                    scombag_assignment_eval $objDefaults.name $objDefaults.value $objNewAlert $objMapConfig $aryNagVars
                }
            }

            $intLoops += 1
            if ($intLoops -ge $intMaxLoops) {
                logger("Stuck in an infinite loop trying to set undefined variables. Trying next item.")
                $bNext = $true
                break
            }
        } while($strUnsetVar) 

        if($bNext) {
            continue
        }

        switch ($aryMainConf['main']['hostname_case']) {
            "lower" {
                $aryNagVars['hostname'] = $aryNagVars['hostname'].ToLower()
                logger("Setting hostname to: " + $aryNagVars['hostname'])
            }
            "upper" {
                $aryNagVars['hostname'] = $aryNagVars['hostname'].ToUpper()
                logger("Setting hostname to: " + $aryNagVars['hostname'])
            }
            "first-upper" {
                $aryNagVars['hostname'] = $aryNagVars['hostname'].substring(0,1).ToUpper() + $aryNagVars['hostname'].substring(1).ToLower()
                logger("Setting hostname to: " + $aryNagVars['hostname'])
            }
            "none" {
                # Do Nothing
            }
            default {
                logger("Incorrect option set for hostname_case")
            }
        }

        if ($aryMainConf['main']['trace_mode_enabled'] -eq 0) {
            $xmlBuilder = generate_alert_xml $aryNagVars
            $bAlertSent = send_alert_to_nagios $xmlBuilder $aryNagVars        

            if ($bAlertSent) {
                $strAlertId = $objNewAlert.Id.ToString()
                if ($aryMappedActivesToProcess.ContainsKey($strAlertId)) {
                    $objNewMappedScomAlerts.actives[$aryMappedActivesToProcess[$strAlertId]].date_modified = $dtCurrentDate.Ticks
                    $objNewMappedScomAlerts.actives[$aryMappedActivesToProcess[$strAlertId]].date_modified_friendly = $dtCurrentDate.DateTime
                } else {
                    $aryAlertProperties = @{"hostname" = $aryNagVars['hostname']; 
										    "service" = $aryNagVars['service'];
										    "nrdpurl" = $aryNagVars['nrdpurl']; 
                                            "nrdptoken" = $aryNagVars['nrdptoken'];
                                            "archived" = "";
                                            "date_created" = $dtCurrentDate.Ticks;
                                            "date_created_friendly" = $dtCurrentDate.DateTime;
                                            "date_modified" = $dtCurrentDate.Ticks;
                                            "date_modified_friendly" = $dtCurrentDate.DateTime;
                                            "guid" = $strAlertId}

                    if ($objNewAlert.IsMonitorAlert -eq $true) {
                        $aryAlertProperties['archived'] = "false"
                        $objNewMappedScomAlerts.actives += $aryAlertProperties
                    } else {
                        $aryAlertProperties['archived'] = "true"
                        $objNewMappedScomAlerts.passives += $aryAlertProperties

                        if ($aryMainConf['main']['scom_rule_auto_close'] -eq 1) {
                            logger("Auto-Close Rules Enabled. Closing this alert.")
                            Get-SCOMAlert -Id $objNewAlert.Id | Set-SCOMAlert -ResolutionState 255
                        }
                    }
                }
            } else {
                logger("Failed to send alert with ID: " +  $strAlertId)
            }
        }

        logger("+++NEXT+++`r`n")
    }

    if ($aryMainConf['main']['trace_mode_enabled'] -eq 0) {
        $jsonOpenScomAlerts = $objNewMappedScomAlerts | ConvertTo-Json
        Set-Content $strTrackFilePath $jsonOpenScomAlerts
    }
}

function send_alert_to_nagios([String]$xmlPost, [Hashtable]$aryNagVars) {
   $webAgent = New-Object System.Net.WebClient
   $nvcWebData = New-Object System.Collections.Specialized.NameValueCollection
   $nvcWebData.Add('token', $aryNagVars['nrdptoken'])
   $nvcWebData.Add('cmd', 'submitcheck')
   $nvcWebData.Add('XMLDATA', $xmlPost)
   $strWebResponse = $webAgent.UploadValues($aryNagVars['nrdpurl'], 'POST', $nvcWebData)
   $strReturn = [System.Text.Encoding]::ASCII.GetString($strWebResponse)
   if ($strReturn.Contains("<message>OK</message>")) {
        logger("SUCCESS - SCOM checks succesfully sent, NRDP returned: $strReturn")
        return $true
   } else {
        logger("ERROR - SCOM checks failed to send, NRDP returned: $strReturn")
        return $false
   }
}

function generate_alert_xml([Hashtable]$aryNagVars) {
    $aryNagVars['output'] = [System.Web.HttpUtility]::HtmlEncode($aryNagVars['output'])
    $xmlBuilder = "<?xml version='1.0'?>`n<checkresults>"
    $xmlBuilder += "`n`t<checkresult type='service' checktype='" + $aryNagVars['activecheck'] + "'>"
    $xmlBuilder += "`n`t`t<hostname>" + $aryNagVars['hostname'] + "</hostname>"
    $xmlBuilder += "`n`t`t<servicename>" + $aryNagVars['service'] + "</servicename>"
    $xmlBuilder += "`n`t`t<state>" + $aryNagVars['state'] + "</state>"
    $xmlBuilder += "`n`t`t<output>" + $aryNagVars['output'] + "</output>"
    $xmlBuilder += "`n`t</checkresult>"
    $xmlBuilder += "`n</checkresults>"
    return $xmlBuilder
}

function scombag_decision_tree([String]$strValueToRetrieve, [PSCustomObject]$objAlert, [PSCustomObject]$objMapConfig, [Hashtable]$aryNagVars) {
    switch -regex ($strValueToRetrieve) {
        "^scombag\.nagios\.get\..*" {
            $aryNagios = $strValueToRetrieve.split(".")
            $strReturn = $aryNagVars.Get_Item($aryNagios[3])
            return $strReturn
        }
        "^scombag\.scom\..*" {
            switch -Regex ($strValueToRetrieve) {
                "^scombag\.scom\.alert\..*" {
                    $aryScomRequest = $strValueToRetrieve.Split(".")
                    $strPropertyToGet = $aryScomRequest[3]
                    $strReturn = $objAlert.$strPropertyToGet
                    return $strReturn
                }
                "^scombag\.scom\.class\..*" {
                    $strAlertClassId = $objAlert.ClassId
                    $objClass = Get-SCOMClass -Id $strAlertClassId
                    $aryScomRequest = $strValueToRetrieve.Split(".")
                    $strPropertyToGet = $aryScomRequest[3]
                    $strReturn = $objClass.$strPropertyToGet
                    return $strReturn
                }
                "^scombag\.scom\.rule\..*" {
                    $strAlertRuleId = $objAlert.RuleId
                    $objRule = Get-SCOMRule -Id $strAlertRuleId
                    $aryScomRequest = $strValueToRetrieve.Split(".")
                    $strPropertyToGet = $aryScomRequest[3]
                    $strReturn = $objRule.$strPropertyToGet
                    return $strReturn
                }
                "^scombag\.scom\.monitor\..*" {
                    $strAlertMonitorId = $objAlert.MonitoringObjectId
                    $objMonitor = Get-SCOMMonitor -Id $strAlertMonitorId
                    $aryScomRequest = $strValueToRetrieve.Split(".")
                    $strPropertyToGet = $aryScomRequest[3]
                    $strReturn = $objMonitor.$strPropertyToGet
                    return $strReturn
                }
            }
        }
        "^scombag\.config\..*" {
            switch -Regex ($strValueToRetrieve) {
                "^scombag\.config\.cat\..*" {
                    $aryConfigRequest = $strValueToRetrieve.Split(".")
                    $strPropertyToGet = $aryConfigRequest[3]
                    $aryVarsToCat = $objMapConfig.cat.$strPropertyToGet
                    $strReturn = ""
                    foreach ($strVarToCat in $aryVarsToCat) {
                        if ($strVarToCat.StartsWith("scombag.")) {
                            $strReturnTemp = scombag_decision_tree $strVarToCat $objAlert $objMapConfig $aryNagVars
                        } else {
                            $strReturnTemp = $strVarToCat
                        }
                        $strReturn = $strReturn + $strReturnTemp
                    }
                    return $strReturn
                }
                "^scombag\.config\.labels\..*" {
                    $aryConfigRequest = $strValueToRetrieve.Split(".")
                    $strPropertyToGet = $aryConfigRequest[3]
                    $strReturn = $objMapConfig.labels.$strPropertyToGet
                    return $strReturn
                }
                "^scombag\.config\.special\.drop$" {
                    return $true
                }
            }
        }
        default {
            logger("Command: $strValueToRetrieve is not a known mapping facility")
            $bReturn = $false
        }
    }
    return $bReturn
}

function scombag_assignment_eval([String]$strKey, [System.Array]$aryValues, [PSCustomObject]$objAlert, [PSCustomObject]$objMapConfig, [Hashtable]$aryNagVars) {
    $strNewVal = ""

    foreach ($strVal in $aryValues) {
        $bBreak = $false
        if ($strVal.StartsWith("scombag.")) {
            $strValTemp = scombag_decision_tree $strVal $objAlert $objMapConfig $aryNagVars
        } else {
            $strValTemp = $strVal
        }

        switch -regex ($strKey) {
            "^scombag\.nagios\.put\.hostname" {
                if ($aryMainConf['main']['host_verify_name'] = 1) {
                    Try {
                        $strDummyVar = [System.Net.Dns]::GetHostAddresses($strValTemp)

                        if ($aryMainConf['main']['strip_fqdn'] = 1) {
                            $strNewVal = $strValTemp -replace "\..*$",""
                        } else {
                            $strNewVal = $strValTemp
                        }

                        if ($strNewVal) {
                            $bBreak = $true
                        }
                    } Catch {
                        $strNewVal = ""
                        continue
                    }
                }
            }
            "^scombag\.nagios\.put\.state" {
                if (($strValTemp -ieq "information") -or ($strValTemp -ieq "ok") -or ($strValTemp -eq "0")) {
                    $strNewVal = 0
                } elseif (($strValTemp -ieq "warning") -or ($strValTemp -eq "1")) {
                    $strNewVal = 1
                } elseif (($strValTemp -ieq "critical") -or ($strValTemp -ieq "error") -or ($strValTemp -eq "2")) {
                    $strNewVal = 2
                } else {
                    $strNewVal = 3
                }
            }
            "^scombag\.nagios\.put\.activecheck" {
                if (($strValTemp -eq $true) -or ($strValTemp -ieq "true") -or ($strValTemp -eq "1")) {
                    $strNewVal = 1
                } else {
                    $strNewVal = 0
                }
            }
            default {
                $strNewVal = $strValTemp
            }
        }

        if ($bBreak) {
            break
        }
    }
    
    $aryNagVar = $strKey.split(".")
    logger("Setting " + $aryNagVar[3] + " to: $strNewVal")
    $aryNagVars.Set_Item($aryNagVar[3], $strNewVal)
    return
}

function scombag_logic_proc([PSCustomObject]$objMapObjects, [PSCustomObject]$objAlert, [PSCustomObject]$objMapConfig, [Hashtable]$aryNagVars, [String]$strParent) { 
    foreach ($strObjName in $objMapObjects.psobject.Properties.Name) {
        $aryLogicMatches = @()

        switch -regex ($strObjName) {
            "^(or|and|not)$" {
                for ($i = 0; $i -lt $objMapObjects.$strObjName.Length; $i++) {
                    $arySubObjectLogicMatches = @()

                    if ($aryMainConf['main']['trace_logic_debug_enabled'] -eq 1) {
                        logger("$strObjName {")
                    }

                    foreach ($strSubObject in $objMapObjects.$strObjName[$i].psobject.Properties.Name) {
                        if ($strSubObject.StartsWith("scombag.")) {
                            $strKeyValue = scombag_decision_tree $strSubObject $objAlert $objMapConfig $aryNagVars
                            $bPatternMatch = $false

                            foreach ($strVal in $objMapObjects.$strObjName[$i].$strSubObject) {
                                if ($strVal.StartsWith("scombag.")) {
                                    $strValValue = scombag_decision_tree $strVal $objAlert $objMapConfig $aryNagVars
                                } else {
                                    $strValValue = $strVal
                                }

                                if ($strKeyValue -match $strValValue) {
                                    $bPatternMatch = $true
                                    break
                                }

                                if ($aryMainConf['main']['trace_logic_debug_enabled'] -eq 1) {
                                    logger("Key: $strKeyValue Val: $strValValue Match: $bPatternMatch")
                                }
                            }
                            
                            $arySubObjectLogicMatches += $bPatternMatch
                        } else {
                            $objChildIteration = [PSCustomObject]@{$strSubObject = $objMapObjects.$strObjName[$i].$strSubObject}
                            $bPatternMatch = $null
                            $bPatternMatch = scombag_logic_proc $objChildIteration $objAlert $objMapConfig $aryNagVars $strObjName

                            if ($aryMainConf['main']['trace_logic_debug_enabled'] -eq 1) {
                                logger("Received: $bPatternMatch From: $strSubObject")
                            }

                            $arySubObjectLogicMatches += $bPatternMatch
                        }
                    }

                    $bPatternMatch = resolve_bool_array $strObjName $arySubObjectLogicMatches

                    if ($aryMainConf['main']['trace_logic_debug_enabled'] -eq 1) {
                        logger("Calculated: $bPatternMatch for this object.")
                    }

                    $aryLogicMatches += $bPatternMatch
                }
            }
            default {
                if ($strObjName -ne "return") {
                    logger("Misconfiguration in json map, invalid logic operator: $strObjName")
                }
                continue
            }
        }

        $bPatternMatch = resolve_bool_array $strParent $aryLogicMatches

        if ($aryMainConf['main']['trace_logic_debug_enabled'] -eq 1) {
            logger("Returning: $bpatternMatch for this object based on parent '$strParent' requirements.")
            logger("}")
        }

        return $bPatternMatch
    }
}

function resolve_bool_array ([String]$strLogicalOperator, [System.array]$aryBooleanCollection) {
    $bPatternMatch = $false

    if ($aryBooleanCollection.Count -lt 1) {
        return $false
    }

    switch ($strLogicalOperator) {
        "or" {
            if ($aryBooleanCollection -contains $true) {
                $bPatternMatch = $true
            }
        }
        "and" {
            if ($aryBooleanCollection -notcontains $false) {
                $bPatternMatch = $true
            }
        }
        "not" {
            if ($aryBooleanCollection -contains $false) {
                $bPatternMatch = $true
            }
        }
        "none" {
            # There should only ever be one element at the root level
            $bPatternMatch = $aryBooleanCollection[0]
        }
    }

    return $bPatternMatch
}

function logger([String]$strMessage) {
    $dtTime = Get-Date
    $strMessage = $dtTime.ToString() + " " + $strMessage
    Write-Host $strMessage
    if ($aryMainConf['logging']['log_enable'] -eq 1) {
        $strLogFile = $aryMainConf['logging']['log_full_path']
        $strMessage | Out-File $strLogFile -Encoding ascii -Append
    }
}

function log_rotate([Datetime]$dtDate) {
    $strLogObject = Get-Item -LiteralPath $aryMainConf['logging']['log_full_path']
    $strLogDir = $aryMainConf['logging']['log_dir']
    $strLogName = $aryMainConf['logging']['log_name'] 
    $intBacklogs = $aryMainConf['logging']['log_backlogs'] - 1
    $strLogRotate = $aryMainConf['logging']['log_rotate']
    $bRotate = $false

    switch ($strLogRotate) {
        "daily" {
            $dtCompareTime = $dtDate.AddDays(-1)
            if ($dtCompareTime.Date -ge $strLogObject.CreationTime.Date) {
                $bRotate = $true
            }
        }
        "weekly" {
            $dtCompareTime = $dtDate.AddDays(-7)
            if ($dtCompareTime.Date -ge $strLogObject.CreationTime.Date) {
                $bRotate = $true
            }
        }
        "monthly" {
            $dtCompareTime = $dtDate.AddMonths(-1)
            if ($dtCompareTime.Date -ge $strLogObject.CreationTime.Date) {
                $bRotate = $true
            }
        }
        default {
            Write-Host "Invalid value: $strLogRotate for log_rotate in configuration file. Unable to continue."
            exit 2
        }
    }

    if ($bRotate) {
        $aryLogs = Get-ChildItem $strLogDir | Where-Object {$_.Name -match "^[0-9]*\-$strLogName"}
        $aryLogs = $aryLogs | sort -Property Name -Descending
        $aryLogs += Get-ChildItem $strLogDir | Where-Object {$_.Name -match "^$strLogName"}
        foreach ($strLog in $aryLogs) {
            if ($strLog.Name -match "^[0-9]*\-$strLogName") {
                $strTempNameParts = $strLog.Name.Split("-")
                $intNewNumber = [int]$strTempNameParts[0] + 1
                if ($intNewNumber -gt $intBacklogs) {
                    Remove-Item $strLog.FullName
                } else {
                    $strNewLogName = $intNewNumber.ToString() + "-" + $strLogName
                    Rename-Item $strLog.FullName $strNewLogName
                }
            } elseif ($strLog.Name -eq $strLogName) {
                $strNewLogName = "0-" + $strLogName
                Rename-Item $strLog.FullName $strNewLogName
            } else {
                continue  
            }
        }
    }
}

function import_main_config([String]$strExecutingPath) {
    $strConfigFile = $strExecutingPath + "scombag_config.ini"

    if (Test-Path $strConfigFile) {
        $aryIniContents = @{}
        switch -regex -file $strConfigFile {
            "^\[(.+)\]$" {
                $strHeading = $Matches[1]
                $aryIniContents[$strHeading] = @{}
            }
            "(.+?)\s*=\s*(.*)" {
                $strKey = $Matches[1]
                $strValue = $Matches[2]
                $aryIniContents[$strHeading][$strKey] = $strValue.Trim()
            }
        }
    } else {
        Write-Host "Unable to find main config file at path: $strConfigFile"
        exit 2
    }

    return $aryIniContents
}

function import_json_config([String]$strJSONFile) {

    if (Test-Path $strJSONFile) {
        Try {
            $objMapConfig = Get-Content $strJSONFile -Raw | ConvertFrom-Json
        } Catch {
            logger("Failed to process " + $strJSONFile + ": " + $Error[0])
            logger("Unable to continue, exiting")
            exit 2
        }
    } else {
        logger("Unable to find map file at path: $strJSONFile")
        logger("Unable to continue, exiting")
        exit 2
    }

    if ($aryMainConf['main']['validate_map'] -eq 1) {
        logger("Config JSON valid, load successful!")
        exit 0
    }

    return $objMapConfig
}

function help {
    $strVersion = "v0.4 b060313"
    $strNRDPVersion = "1.2"
    Write-Host "Scombag version: $strVersion for NRDP version: $strNRDPVersion"
    Write-Host "By John Murphy <john.murphy@roshamboot.org>, GNU GPL License"
    Write-Host "Usage: ./scombag.ps1`n"
    Write-Host @'
-help
	Display this help text.
-validate_map
    Validate the JSON in the map configuration.
-enable_tracing
    Execute the script and output information without actually committing anything to Nagios.
-trace_guid
	Run the trace on a specific SCOM alert Id.
-logic_debugging
    Enable debugging of the pattern matching logic.
'@
    exit 0
}

##########################################
### BEGIN MAIN
##########################################
if ($help) {
    help
}

$strExecutingPath = Split-Path -parent $PSCommandPath
Set-Location -Path $strExecutingPath

if (!("\" -eq $strExecutingPath.Substring($strExecutingPath.Length - 1, 1))) {
    $strExecutingPath = $strExecutingPath + "\"
}

$aryMainConf = import_main_config($strExecutingPath)
Set-Variable -Name $aryMainConf -Scope Global

$strMapFile = $strExecutingPath + $aryMainConf['main']['map_file']

if ($validate_map) {
    $aryMainConf['main']['validate_map'] = 1
    $aryMainConf['logging']['log_enable'] = 0
    import_json_config($strMapFile)
}

if ($enable_tracing) {
    $aryMainConf['main']['trace_mode_enabled'] = 1
    if ($logic_debugging) {
        $aryMainConf['main']['trace_logic_debug_enabled'] = 1
    }
}


if ($aryMainConf['logging']['log_enable'] = 1) {
    if (!("\" -eq $aryMainConf['logging']['log_dir'].Substring($aryMainConf['logging']['log_dir'].Length - 1, 1))) {
        $aryMainConf['logging']['log_dir'] = $aryMainConf['logging']['log_dir'] + "\"
    }

    if (Test-Path $aryMainConf['logging']['log_dir']) {
        $aryMainConf['logging']['log_full_path'] = $aryMainConf['logging']['log_dir'] + $aryMainConf['logging']['log_name']
    } elseif (Test-Path $strExecutingPath + $aryMainConf['logging']['log_dir']) {
        $aryMainConf['logging']['log_full_path'] = $strExecutingPath + $aryMainConf['logging']['log_dir'] + $aryMainConf['logging']['log_name']
    } else {
        Write-Host "Can't find log directory. Unable to continue."
        exit 2
    }

    $dtStartTime = Get-Date

    $bLogExists = Test-Path $aryMainConf['logging']['log_full_path']

    if($bLogExists) {
        log_rotate($dtStartTime)
    }

    Add-Content $aryMainConf['logging']['log_full_path'] "`r`n############################################################" 
    Add-Content $aryMainConf['logging']['log_full_path'] "SCOMBAG started at: $dtStartTime"
}

Import-Module OperationsManager -ErrorVariable strImportError

if ($strImportError) {
    logger("Error loading one or more module(s): " + $strImportError)
    logger("Unable to continue.")
    exit 2
}

$strRMSEmulator = Get-SCOMRMSEmulator
$strServerFQDN = $env:COMPUTERNAME + "." + $env:USERDNSDOMAIN

if (($strRMSEmulator.DisplayName -ieq $strServerFQDN) -or ($aryMainConf['main']['trace_mode_enabled'] -eq 1)) {
    if ($aryMainConf['main']['trace_mode_enabled'] -eq 1) {
        logger("Trace mode enabled. This is a tracing run.")
    }

    logger("Beginning SCOM -> Nagios map import")
    $objMapConfig = import_json_config($strMapFile)

    logger("Beginning main processing")
    process_alerts $objMapConfig $strExecutingPath $trace_guid
} else {
   logger("This server is not the RMS emulator. Skipping processing this run.")
}