=========================================
Introduction
=========================================
This script is designed to provide a flexible method of forwarding SCOM 2012 alerts to Nagios.

=========================================
Pre-Install Requirements
========================================= 
- NRDP must be installed and configured on the Nagios server.
 
=========================================
Installation
=========================================
1. Extract the contents of this zip file to a directory on your SCOM 2012 server.  
2. Open Windows task scheduler (Run taskschd.msc in a powershell command prompt).  
3. Select the "Task scheduler library" heading and then select "Create Task..." from the right hand menu.  
4. Give it a meaningful name (i.e. SCOM To Nagios).  
5. Click the "Change User or Group..." button and select a user with at least full read access to SCOM.  
6. Select the "Run whether user is logged on or not" radio box.  
7. Change to the "Triggers" tab and click the "New..." button.  
8. Set the following options and click OK:  
- Begin the task: On a schedule  
- Daily radio box selected  
- Recur every 1 days  
- Repeat task every 10 minutes for duration of 1 day  
- Stop task if it runs longer than 10 minutes.  
- Enabled  
9. Change to the "Actions" tab and click the "New..." button.  
10. Set the following options and click OK:  
- Action: Start a program  
- Program/Script: powershell  
- Add arguments (optional): -file "C:\path\to\script\directory\scombag.ps1"  
11. Click OK to save the new scheduled task.  

For those with multiple SCOM 2012 servers, the script will ONLY execute on the server with the RMS Emulator role to prevent it executing on multiple SCOM servers simultaneously.

=========================================
Upgrading
=========================================
1. Replace the scombag.ps1 file and the scombag_map.ini file. Version 0.1 configuration is not compatible with version 0.2.

=========================================
Configuration
=========================================
Main config file (scombag_config.ini) option explanation:

[main]  
scom_rule_auto_close - 0/1 - Allow this script to close rules in SCOM after it has forwarded them to Nagios.  
strip_fqdn - 0/1 - If enabled the script will strip the FQDN from the hostname before forwarding to Nagios.  
map_file - mapfile_name.json - Name of the JSON map file to load for instructions about translating information.   
hostname_case - lower/upper/first-upper/none - Convert the case of the hostname (and FQDN) to the selected case. First-upper will change the first letter to upper case. 
trace_mode_enabled - 0/1 - Enable or disable tracing mode (see execution usage option enable_tracing).  

[track]  
trk_file - trackingfile_name.json - Name of the JSON tracking file to use for keeping track of what information has been forwarded to Nagios.  
trk_archive_days_ttl - # - A number specifying how many days a closed entry in the tracking file will remain (for debugging purposes).  
trk_alert_max_ttl - # - A number specifying how many days an alert can remain open before it is automatically closed to prevent unforseen circumstances keeping an alert open forever.  
trk_resend_alert - # - If an alert hasn't been closed in SCOM within the number of days specified for this option a new alert will be forwarded to Nagios.  

[logging]  
log_enable - 0/1 - Enable or disable logging.  
log_dir - dir - The name of the directory for storing the log files.  
log_name - log_name.log - The name of the log file.  
log_rotate - daily/weekly/monthly - How often to rotate the log files, daily is recommended.  
log_backlogs - # - The number of backlogs to keep. If you have a daily log rotation and a backlogs value of 5, you will have five days of logs.  

=========================================
Field mapping
=========================================
Configuring the field mappings for the scombag script at first seems incredibly daunting, the syntax looks pretty wild but once you understand it, it's not so bad.  

Introduction
---------------------------
Many of the concepts in SCOM and Nagios are directly transferable (i.e. State information and Active/Passive (or Rules/Monitors) data gathering). However SCOM suffers horribly when it comes to the flexibility of its output capabilities. The goal of this script is to sidestep those problems and to achieve that end the script uses the OperationsManager Powershell plugin to extract the data and then compare it with the contents of the socmbag_map.json file to make decisions on what to do with the alert.

This is accomplished by taking a value from SCOM and then either directly mapping it to a Nagios attribute or by using a series of logical operators (and, or, not) combined with regex comparisons to determine what values need to be forwarded to Nagios. A custom built language framework designed for operation with this script (described in the Config Language sub-section) makes it simple to extract and map values.

Config Sections - Overview
---------------------------
The scombag_map.json file consists of five main sections that perform different functions. These sections are "map", "logicmap", "default", "labels" and "cat".  
The mentioned sections do the following:  

map - Directly map the value from a SCOM field to a Nagios field.  

logicmap - Uses a logical "and", "or", "not" structure to determine if an alert matches certain criteria, you can then set Nagios fields based on if it matches the defined criteria. This is the heart and soul of the script.  

default - If map or logicmap fails to generate a value for a Nagios field the default section can be used to give it a default value and/or override other Nagios fields.

labels - A label is a quick way of defining re-useable text, it also allows you to use plain text as a key in the logicmap. This is useful if you refer to something repeatedly... like perhaps the NRDP URL or a specific host match pattern, this way you only need to update it in one place if it changes.

cat - The cat section is used for concatenating text together to create messages.

*NOTE* At some stage in the future the labels and cat section may be merged... as well as the map and logicmap sections.

Config Language
---------------------------
Before we can begin to talk about the five sections mentioned above in detail it's important to understand the language that the scombag script understands for extracting and mapping values. The essence of it is you combine four key words seperated by a dot character that detail the action you want to take.

The first word is always scombag, the second word is always the system you want to interact with (scom, nagios or config), so your first two fields will always be either scombag.scom, scombag.nagios or scombag.config. Below these first two layers though the key words vary greatly depending on which system you are interacting with.

The format for scombag.nagios is roughly: scombag.nagios.action.nagios_var  
The format for scombag.scom is roughly: scombag.scom.powershell_command.property_to_get  
The format for scombag.config is roughly: scombag.scom.section.element_name  

The actions for scombag.nagios are get or put, with the nagios_vars being your standard NRDP input vars (nrdpurl, nrdptoken, hostname, service, state, output, activecheck). So if I wanted to assign a hostname to a static string I would use "scombag.nagios.put.hostname": "myhostname", simple enough?

Later on in the mapping I may want to check if the assigned hostname matches a specific pattern so I can determine if it needs to go to a particular kind of service... I would then use "scombag.nagios.get.hostname": "myhost*" When doing a scombag.nagios.put certain fields have built-in translation features to make the mapping process easier. These fields are listed below:

scombag.nagios.put.activecheck = Will accept the values 0/1 or True/False which allows you to use "scombag.nagios.put.activecheck": "scombag.scom.alert.IsMonitorAlert"

scombag.nagios.put.hostname = To solve the problem of SCOM putting the hostname wherever it damn well pleases, it will accept an array of values and attempts to resolve the IP address for each value. If an address is not found it gives up. This allows you to configure a hostname in the format:  
"scombag.nagios.put.hostname": ["scombag.scom.alert.NetbiosComputerName","scombag.scom.alert.MonitoringObjectDisplayName","scombag.scom.alert.MonitoringObjectPath","scombag.scom.alert.Parameters"]

scombag.nagios.put.state = Will accept the values 0/1/2 or ok/warning/error or information/warning/critical which allows you to do "scombag.nagios.put.state": "scombag.scom.alert.Severity"

The scombag.scom namespace is going to be easier for some people and harder for others, the reason for this is that you must use powershell to explore what elements you want to compare and map. Each of the key words in the third field is related to a particular scom get command, these are listed below.  
scombag.scom.alert = Get-SCOMAlert  
scombag.scom.class = Get-SCOMClass  
scombag.scom.rule = Get-SCOMRule  
scombag.scom.monitor = Get-SCOMMonitor  

This means the fourth field is a property belonging to the corresponding powershell commandlet, so if you wanted to get the name of the class a particular alert belongs to you would use scombag.scom.class.Name. This is particularly useful when you want to send SCOM exchange alerts to an exchange service in Nagios, to achieve this you would have an entry in your logicmap containing: "scombag.scom.class.Name": "Microsoft\\.Exchange.*"

The last namespace scombag.config is used for accessing the values in the cat or label sections of the configuration. So suppose you have a label which defines the production NRDP URL and you want to assign it in your logicmap you would use "scombag.nagios.put.nrdpurl": "scombag.config.label.prod_nrdp". This should become clearer when you look at the examples below.

Config Sections - Detailed
---------------------------
Now that you are probably at the height of your confusion lets begin to make sense of it all and look at how these pieces work together to actually solve the problem.

Label  
***********  
Labels are the simplest building block and are great for data that is used repeatedly and if the value changes in the future you only need to redefine it in the label instead of all through out the script. They are defined with a simple key/value pair where the key is the text string you use to access it later and the value is what you want to insert when it is called.

*NOTE* You may also notice in the below example that when we are escaping with a backslash in a regex string we are double escaping. This is because when the json file is imported it also uses backslash as an escape character.

The label section would look something like:  
"labels": {  
	"prod_nagios_nrdpurl": "http://nagios-prod/nrdp",  
	"prod_nagios_nrdptoken: "123135467524",  
	"test_nagios_nrdpurl": "http://nagios-test/nrdp",  
	"test_nagios_nrdptoken": "12464711256",  
	"prod_servers_pattern": "^prod\\-.*$",  
	"test_servers_pattern": "^test\\-.*$",  
	"undefined": "^$"
}  

Cat  
***********  
Concatenations are very similar to a label except instead of simple key/value pairs they are used for concatenating a series of different strings together which is useful for creating custom output messages from multiple different SCOM fields. To create a cat element, instead of defining a key and a value you define a key and an array of values.

A sample cat section might look like:  
"cat": {  
	"output": ["scombag.scom.alert.Name"," --- ","scombag.scom.alert.Description"],  
	"errormessage": ["A problem occured trying to get SCOM output for UID: ","scombag.scom.alert.Id"],  
}  

Map  
***********  
As previously stated the Map section allows us to map directly from SCOM to Nagios, this makes it ideal for "deterministic" fields. Such fields are likely to be the alert state, hostname, output and if it is an activecheck or not. The reason for this is these fields are easy to translate, it's likely that the source and destination for the information related to those fields is unlikely to alter what you want to do with the alert from a mapping perspective.

A map definition is usually a simple key/value pair where the key is a scombag.nagios.put command. An example map definition can be seen below:  
"map": {  
	"scombag.nagios.put.activecheck": "scombag.scom.alert.IsMonitorAlert",  
	"scombag.nagios.put.output": "scombag.config.cat.output",  
	"scombag.nagios.put.hostname":   ["scombag.scom.alert.NetbiosComputerName","scombag.scom.alert.MonitoringObjectDisplayName","scombag.scom.alert.MonitoringObjectPath","scombag.scom.alert.Parameters"],  
	"scombag.nagios.put.state": "scombag.scom.alert.Severity"  
}  

Default  
***********  
The default section serves a very vital function, in the event that something can't be mapped properly the default section will be referred to in order to determine what it should do. Some fields being missing will be easy to recover from e.g. activecheck is not a particularly vital field and an assumption can be made. However for fields like service, if you can't determine that then other parts of your information may also be unreliable.

Defining elements in default is a little more complex than the previously discussed sections. The top level key in this case is one of the valid nagios values with a number of sub key/value pairs.

Your default section may look like:  
"default": {  
	"nrdpurl": {  
		"scombag.nagios.put.nrdpurl": "scombag.config.label.prod_nagios_nrdpurl",  
		"scombag.nagios.put.nrdptoken": "scombag.config.label.prod_nagios_nrdptoken",  
		"scombag.nagios.put.hostname": "default-host",  
		"scombag.nagios.put.service": "SCOM NO VALID MAP ASSIGNED"  
	},  
	"nrdptoken": {  
		"scombag.nagios.put.nrdpurl": "scombag.config.label.prod_nagios_nrdpurl",  
		"scombag.nagios.put.nrdptoken": "scombag.config.label.prod_nagios_nrdptoken",  
		"scombag.nagios.put.hostname": "default-host",  
		"scombag.nagios.put.service": "SCOM NO VALID MAP ASSIGNED"  
	},  
	"hostname": {  
		"scombag.nagios.put.nrdpurl": "scombag.config.label.prod_nagios_nrdpurl",  
		"scombag.nagios.put.nrdptoken": "scombag.config.label.prod_nagios_nrdptoken",  
		"scombag.nagios.put.hostname": "default-host",  
		"scombag.nagios.put.service": "SCOM NO VALID MAP ASSIGNED"  
	},  
	"service": {  
		"scombag.nagios.put.nrdpurl": "scombag.config.label.prod_nagios_nrdpurl",  
		"scombag.nagios.put.nrdptoken": "scombag.config.label.prod_nagios_nrdptoken",  
		"scombag.nagios.put.hostname": "default-host",  
		"scombag.nagios.put.service": "SCOM NO VALID MAP ASSIGNED"  
	},  
	"state": {  
		"scombag.nagios.put.state": "Warning"  
	},  
	"output": {  
		"scombag.nagios.put.output": "scombag.config.cat.errormessage"  
	},  
	"activecheck": {  
		"scombag.nagios.put.activecheck": "0"  
	}	  
}  

LogicMap  
***********  
This last section is by far the most complex but is the most powerful part of this whole integration piece. The logic map allows you to nest "or, not, and" logical statements to make decisions about pattern matching in order to determine a resulting value for a Nagios field. This means you can send your Exchange SCOM alerts to an Exchange service in Nagios, or maybe the Database alerts to a Database service. You can differentiate between Prod and Test servers if you happen to be running both out of the same SCOM instance. You can do a lot of powerful stuff.

Achieving this though does require some setup time. The top level object under logicmap is a name for that particular pattern... this has no importance other than making it easy for you to remember what the pattern is for. It does however have to be unique and ideally should not contain spaces.

Under each of these top level objects you will have two more objects, the root for your logical "and, or, not" evaluation section and the actions to perform if the logical section is evaluated to true (this is called the "return" element as it commonly defines what information is returned to Nagios). 

The logical definitions are always defined as an array of objects this allows you to do multiple of the same logical object per layer, however the logical root can only ever have one definition. 

A lot of this is very difficult to understand from a text definition, the following example should do more to further your understanding:  
"logicmap": {  
"nagios-prod": {  
	"and": [ {  
		"scombag.nagios.get.hostname": "scombag.config.labels.prod_servers_pattern"  
	} ],  
	"return": {  
		"scombag.nagios.put.nrdpurl": "scombag.config.label.prod_nagios_nrdpurl",  
		"scombag.nagios.put.nrdptoken": "scombag.config.label.prod_nagios_nrdptoken"  
	}  
},  

"nagios-test": {  
	"or": [ {  
		"scombag.nagios.get.hostname": "scombag.config.labels.test_servers_pattern"  
	} ],  
	"return": {  
		"scombag.nagios.put.nrdpurl": "scombag.config.label.prod_nagios_nrdpurl",  
		"scombag.nagios.put.nrdptoken": "scombag.config.label.prod_nagios_nrdptoken" 
	}  
},  
  
"generic-server": {  
	"and": [ {  
		"not": [ {  
			"scombag.scom.class.Name": "Microsoft\\.Windows\\.Server\\..*\\.AD.*"  
		} ],  
		"or": [ {  
			"scombag.scom.class.Name": [  
				"Microsoft\\.SystemCenter\\.HealthService.*",  
				"Microsoft\\.Windows\\.Server.*",  
				"Microsoft\\.Windows\\.Cluster.*",  
				"Microsoft\\.Windows\\..*\\.DHCP.*",  
				"Windows\\.Backup\\.Class\\.Windows\\.Backup\\.Status"  
			],  
			"and": [ {  
				"scombag.scom.class.Name": "Microsoft\\.Windows.*",  
				"scombag.scom.alert.MonitoringObjectDisplayName": ".*Windows Server.*"  
			} ]  
		} ]  
	} ],  
	"return": {  
		"scombag.nagios.put.service": "Generic Server SCOM Alerts"  
	}  
},  

"exchange-server": {  
	"or": [ {  
		"scombag.scom.class.Name": "Microsoft\\.Exchange.*"  
	} ],  
	"return": {  
		"scombag.nagios.put.service": "Exchange SCOM Alerts"  
	}  
},  

"AD-server": {  
	"or": [ {  
		"scombag.scom.class.Name": "Microsoft\\.Windows\\.Server\\..*\\.AD.*",  
		"scombag.scom.class.Name": "Microsoft.Windows.DNSServer.Library.Server"  
	} ],  
	"return": {  
		"scombag.nagios.put.service": "AD SCOM Alerts"  
	}  
},  
}  

=========================================
Usage
=========================================
From a Nagios perspective configuring this plugin is dead-simple, it pretty much operates like any other passive service. The only key difference is that for SCOM alerts you may not want to set a freshness threshold (or at the very least ensure that it is set longer than the SCOMBAG resend timer). The reason for this is that Alerts function much like normal Nagios queries... which means they will correct themselves once the issue is solved.

See the installation instructions for setting up automated alert forwarding.

Execution Usage:  
./scombag.ps1  
	
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
	
=========================================
Patch notes
=========================================
v0.3:  
- Complete re-write of the tracking file code.
- Tracking file format has changed.
- *NEW* Experimental scombag.config.special.drop command

v0.2:  
- Complete re-write of the logic processing engine.
- Slight changes to the map file format.
- *NEW* Logic debugging mode.

v0.1:  
- First release
