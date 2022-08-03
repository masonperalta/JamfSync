#!/bin/bash
#############################
# Sync Jamfcloud Data
# Mason Peralta
###############################################################################################
# The purpose of this script is to sync specific data points from Jamfcloud to an on-premise 
# MySQL database hosted on a Linux (Ubuntu) server.  The script is intended to automatically 
# run on the server at a set interval (crontab) but can also be run manually from a remote Mac.
###############################################################################################
#
#
#
#
#
####################
##### Settings #####
####################
syncMobileDevices_TF=true 
syncComputers_TF=true   
syncComputerExtensionAttributes_TF=true
syncMobileDeviceExtensionAttributes_TF=true
testMode_TF=false  
debugMode_TF=true 
debugModeLogAllSyncedDataToTxtFiles_TF=false
authTypeUseBearer_TF=true 
useJPApiForFullIds_TF=true
###############################################################################################################
##### action taken when script encounters a computer or device that has been deleted from source Jamf Pro #####
deleteBehavior="unmanage"  ##### options: "delete", "unmanage" or "" #####
##### Jamf Pro record pull method - using "search" or "filter" can be more efficient in large environments ####
efficiencyMode="" ##### options: "", "search", "filter" ## $useJPApiForFullIds_TF must be set to false ###
##### the number of days that log files remain in log file direcotry before they are automatically deleted  ###
deleteLogsOlderThan="14"  ##### enter value in number of days #####
###############################################################################################################
#####################
##### Variables #####
#####################
envFile=~/.sync_jamfcloud_data.env
cnfFile=~/.my.cnf
if [[ -f $envFile ]] && [[ -f $cnfFile ]]
then
	# Load Environment Variables
	export $(cat "$envFile" | grep -v '#' | awk '/=/ {print $1}')
else
	echo "environmental variable file(s) not found. Exiting...."
	exit 1
fi
apiUser=$JSSUSER
apiPass=$JSSPASS
jss=$JSS
jamfDBname=$JAMFDBNAME 
jamfDBHost=$JAMFDBHOST
jamfDBuser=$(cat $cnfFile | grep "user=" | awk -F= '{print $2}')
##### path to local mysql client to set credentials, database and run commands on Ubuntu server or Intel or Apple Silicon Macs (installed via Homebrew on Macs)
ubuntuCheck=$(which lsb_release)
if [[ "$ubuntuCheck" != "" ]]
then
	echo "script running on Ubuntu...."
	MYSQL="mysql -sN --host=${jamfDBHost} --user=${jamfDBuser} ${jamfDBname}"
else
	echo "script not running on Ubuntu, switching to macOS environment...."
	arch=$( /usr/bin/arch )
	if [[ "$arch" == "arm64" ]]
	then
		MYSQL="/opt/homebrew/Cellar/mysql-client/8.0.27/bin/mysql -sN --host=${jamfDBHost} --user=${jamfDBuser} ${jamfDBname}"
	else
		MYSQL="/usr/local/opt/mysql-client/bin/mysql -sN --host=${jamfDBHost} --user=${jamfDBuser} ${jamfDBname}"
	fi
fi
################
## Temp files ##
tmpFileDir=/tmp
tmpResponseCode="${tmpFileDir}/jss_temp_response_code.txt"
tmpAdvancedSearch="${tmpFileDir}/jss_temp_advanced_search.xml"
################
## Log files  ##
now=$(date +'%Y%m%d-%H%M%S')
nowEpochMilliseconds="$(date +%s)000"
logFileDir=~/JamfSync
logFilePath="${logFileDir}/jamfProDbSync_${now}.log"
lastSyncFile=~/.lastSync.txt
lastSyncEpoch=$(cat "$lastSyncFile")
###############
## Log Vars  ##
computersCreated=0
computersUpdated=0
computersDeleted=0
computersUnmanaged=0
devicesCreated=0
devicesUpdated=0
devicesDeleted=0
devicesUnmanaged=0
startScriptEpochSeconds=""
stopScriptEpochSeconds=""
responseCode=""
scriptVersion="0.1.3"
#####################
##### Functions #####
#####################

function setLastSync() {
	# This function writes a receipt file with the last successful sync timestamp.
	# New computer / device DB uploads compare this to determine if their MySQL entry should be updated or kept the same.
	# Skips if testMode is enabled
	if [[ "$testMode_TF" == false ]]
	then
		if [[ -f "$lastSyncFile" ]]
		then
			rm -rf "$lastSyncFile"
		fi
		echo "INFO: Finishing up. Writing last sync timestamp...." >> "$logFilePath"
		echo "$nowEpochMilliseconds" > "$lastSyncFile"
	fi
}

function convertEpochTimestampToStandardOrRsql() {
	convertType=$1
	# This function converts the lastSync epoch timestamp to a standard-readable date (2022-01-27) to be used in creating temporary Advanced Searches
	lastSynchEpochWithoutMilliseconds=${lastSyncEpoch%???} #deletes last 3 digits "000" from epoch
	
	if [[ "$convertType" == "" ]]
	then
		# converting epoch to standard time
		if [[ "$ubuntuCheck" != "" ]]
		then
			standardDate=$(date -d @$lastSynchEpochWithoutMilliseconds +'%Y-%m-%d')
		else
			standardDate=$(date -r $lastSynchEpochWithoutMilliseconds +'%Y-%m-%d')
		fi
	else
		# converting epoch to RSQL time
		if [[ "$ubuntuCheck" != "" ]]
		then
			rsqlDate=$(date -d @$lastSynchEpochWithoutMilliseconds +'%Y-%m-%d'T'%H:%M:%S'.888Z | awk '{gsub(":", "%3A");print}')
		else
			rsqlDate=$(date -r $lastSynchEpochWithoutMilliseconds +'%Y-%m-%d'T'%H:%M:%S'.888Z | awk '{gsub(":", "%3A");print}')
		fi
	fi
}


function generateAuthToken() {
	# Use user account's username and password credentials with Basic Authorization to request a bearer token
	# Process differs for computers running macOS before version 12
	# Create base64-encoded credentials from user account's username and password.
	encodedCredentials=$(printf "${apiUser}:${apiPass}" | /usr/bin/iconv -t ISO-8859-1 | /usr/bin/base64 -i -)
	# Use the encoded credentials with Basic Authorization to request a bearer token
	authToken=$(/usr/bin/curl "${jss}/api/v1/auth/token" --silent --request POST --header "Authorization: Basic ${encodedCredentials}")
	# Parse the returned output for the bearer token and store the bearer token as a variable.
	if [[ "$ubuntuCheck" != "" ]]
	then
		api_token=$(/usr/bin/awk -F \" 'NR==2{print $4}' <<< "$authToken" | /usr/bin/xargs)
	else
		if [[ $(/usr/bin/sw_vers -productVersion | awk -F . '{print $1}') -lt 12 ]]
		then
			api_token=$(/usr/bin/awk -F \" 'NR==2{print $4}' <<< "$authToken" | /usr/bin/xargs)
		else
			api_token=$(/usr/bin/plutil -extract token raw -o - - <<< "$authToken")
		fi
	fi
	
	verifyAuthToken
}

function verifyAuthToken() {
	api_authentication_check=$(/usr/bin/curl --write-out %{http_code} --silent --output /dev/null "${jss}/api/v1/auth" --request GET --header "Authorization: Bearer ${api_token}")	
	debugging "VERIFYING AUTH TOKEN TO $jss. Status: [$api_authentication_check]"
	# set start time of token validation to renew right before expiration
	tokenGeneratedTimeStart=$(date +%s)

}

function checkTokenTimeout() {
	# Checks how long token has been active in order to deterine when to renew
	tokenCheckTimestamp=$(date +%s)
	tokenAge=$((tokenCheckTimestamp - tokenGeneratedTimeStart))
		
	if [[ "$authTypeUseBearer_TF" == true ]]
	then
		# generates new token if previous is 25+ minutes old (5 minute buffer is given to finish any large inventory uploads)
		if [[ "$tokenAge" -ge 1500 ]]
		then
			echo "INFO: AUTH TOKEN IS $tokenAge SECONDS OLD. Generating new token to continue access...." >> $logFilePath
			setApiAuthenticationType 
		else
			debugging "INFO: AUTH TOKEN [OK]: $tokenAge SECONDS OLD...."
		fi
	fi
}

function setApiAuthenticationType() {
	# Setting up API calls to use either basic or bearer token authentication
	if [[ "$authTypeUseBearer_TF" == true ]]
	then
		generateAuthToken
		auth="Authorization: Bearer ${api_token}"
		option="-H"
	else
		auth="$apiUser:$apiPass"
		option="-u"

	fi
}

function getAllIds() {
	checkTokenTimeout
	# This function pulls all computer / mobile device IDs from the Jamf instance using the Classic Jamf API
	deviceType=$1
	tmpFilePath="${tmpFileDir}/jss_temp_all_${deviceType}.xml"
	if [[ "$efficiencyMode" == "filter" ]] || [[ "$useJPApiForFullIds_TF" == true ]]
	then
		tmpFilePath="${tmpFileDir}/jss_temp_all_${deviceType}.json"
	fi
	# only run the curl commands below if not using the JPAPI to retrieve all IDs
	if [[ "$useJPApiForFullIds_TF" == false ]]
	then
		# only run the api call in the below function if efficiencyMode is set to "" and not another option
		if [[ "$efficiencyMode" == "" ]] || ! [[ -f "$lastSyncFile" ]]
		then
			if [[ "$deviceType" == "computers" ]]
			then
				# using the /subset/basic option to get the IDs and last report_date_epoch to compare timestamps.  This is not available for mobile devices.
				# below we send the xml output to the /tmp/jss_temp_all_$deviceType.xml file and send the response output to /tmp/jss_temp_response_code.txt
				curl -s -v $option "$auth" "${jss}/JSSResource/${deviceType}/subset/basic" -X GET -H "accept: application/xml" > "$tmpFilePath" 2> "$tmpResponseCode"
				checkApiResponseCode
				
			elif [[ "$deviceType" == "mobiledevices" ]]
			then
				curl -s -v $option "$auth" "${jss}/JSSResource/${deviceType}" -X GET -H "accept: application/xml" > "$tmpFilePath" 2> "$tmpResponseCode"
				checkApiResponseCode
			else
				echo "ERROR: Incorrect parameter used for deviceType in function getAllIds()...." >> "$logFilePath"
				exit 1
			fi
		else
			echo "" > "$tmpFilePath"
		fi
	else
		echo "" > "$tmpFilePath"
	fi
	
	echo "$tmpFilePath"
}

function getAllIdsByAdvancedSearch() {
	# this function will generate a more efficient list of computer / mobile device IDs by creating a temporary Advanced Computer / Mobile Device Search and
	# returning only the deivces that have reported back to Jamf since the most recent script sync.  Note that getAllIds() must run first in order to generate
	# a complete list of devices in order to compare old / new records and perform deleteBehavior.
	deviceType=$1
	tmpFilePath="${tmpFileDir}/jss_temp_all_${deviceType}.xml"
	rm -rf "$tmpFilePath"
	convertEpochTimestampToStandardOrRsql
	tempAdvancedSearchName="JamfSyncScriptTemporaryAdvancedSearch"
	
	if [[ "$deviceType" == "computers" ]]
	then
		postRequest="<advanced_computer_search><name>${tempAdvancedSearchName}</name><view_as>Standard Web Page</view_as><sort_1/><sort_2/><sort_3/><criteria><size>1</size><criterion><name>Last Inventory Update</name><priority>0</priority><and_or>and</and_or><search_type>after (yyyy-mm-dd)</search_type><value>$standardDate</value><opening_paren>false</opening_paren><closing_paren>false</closing_paren></criterion></criteria><display_fields><size>0</size></display_fields><computers></computers><site><id>-1</id><name>None</name></site></advanced_computer_search>"
		
		searchType="advancedcomputersearches"
		search_Type_Root="advanced_computer_search"
		logSearchType="Advanced Computer Search"
		
	elif [[ "$deviceType" == "mobiledevices" ]]
	then
		postRequest="<advanced_mobile_device_search><name>$tempAdvancedSearchName</name><view_as>Standard Web Page</view_as><sort_1/><sort_2/><sort_3/><criteria><size>1</size><criterion><name>Last Inventory Update</name><priority>0</priority><and_or>and</and_or><search_type>after (yyyy-mm-dd)</search_type><value>$standardDate</value><opening_paren>false</opening_paren><closing_paren>false</closing_paren></criterion></criteria><display_fields><size>0</size></display_fields><mobile_devices></mobile_devices><site><id>-1</id><name>None</name></site></advanced_mobile_device_search>"
		
		searchType="advancedmobiledevicesearches"
		search_Type_Root="advanced_mobile_device_search"
		logSearchType="Advanced Mobile Device Search"
		
	fi
		advancedComputerSearchID=""
		
		# creating new temporary advanced search at /id/0 in order to filter out computers / devices that have not checked in since last sync
		curl -s -v $option "$auth" "$jss/JSSResource/$searchType/id/0" -H "content-type: application/xml" -X POST -d "${postRequest}" 2> "$tmpResponseCode"
		checkApiResponseCode
		# get the APBALANCEID from the previous call and use it for session by using curl -b
		cookie=$APBALANCEID
		# getting list of Advanced Computer Searches to review all names / IDs
		curl -s -v -b "$cookie" $option "$auth" "$jss/JSSResource/$searchType" -X GET -H "accept: application/xml" > "$tmpAdvancedSearch" 2> "$tmpResponseCode"
		checkApiResponseCode
		
		local advancedSearchResultsCount=$(cat "$tmpAdvancedSearch" | xmllint --xpath "count(//$search_Type_Root/id)" -)
		
		nameFoundCount=0
		nameFoundList=""
		# Iterate through all names / IDs until we find the one we created
		for i in $(seq 1 $advancedSearchResultsCount)
		do
			local advancedComputerSearchName=$(cat "$tmpAdvancedSearch" | xmllint --xpath "((//$search_Type_Root)[$i]/name)" - | sed -e 's/<[^>]*>//g'; echo)
			tempAdvancedComputerSearchID=$(cat "$tmpAdvancedSearch" | xmllint --xpath "((//$search_Type_Root)[$i]/id)" - | sed -e 's/<[^>]*>//g'; echo)
			
			if [[ "$advancedComputerSearchName" == "$tempAdvancedSearchName" ]]
			then
				advancedComputerSearchID=$tempAdvancedComputerSearchID
				nameFoundCount=$((nameFoundCount+1))
				nameFoundList=$(echo "$nameFoundList $tempAdvancedComputerSearchID " )
			fi
		done
		
		debugging "INFO: ${logSearchType}es found with name $tempAdvancedSearchName: $nameFoundCount...."
		if [[ $nameFoundCount -gt 1 ]]
		then
			echo "ERROR: $nameFoundCount IDs found for $tempAdvancedSearchName. Redundant entries will be deleted at IDs $nameFoundList...." >> $logFilePath
		fi
		debugging "INFO: $logSearchType ID being used for $tempAdvancedSearchName: $advancedComputerSearchID...."
		
		# write out the XML of all computers that have checked in to Jamf since the last sync
		curl -s -v -b "$cookie" $option "$auth" "$jss/JSSResource/$searchType/id/$advancedComputerSearchID" -X GET -H "accept: application/xml" > "$tmpFilePath" 2> "$tmpResponseCode"
		checkApiResponseCode		
		# delete the temporary advanced computer / mobile device search we just created and any others previously created but not previously deleted
		for delete in ${nameFoundList[@]}
		do
			delete=$(echo "$delete" | tr -d " ")
			curl -s -v -b "$cookie" $option "$auth" "$jss/JSSResource/$searchType/id/$delete" -X DELETE > "$tmpAdvancedSearch" 2> "$tmpResponseCode"
			debugging "INFO: Deleting $logSearchType $tempAdvancedSearchName with ID $delete...."
			checkApiResponseCode
		done
}

function getAllIdsByProApiFilter() {
	checkTokenTimeout
	# $1 is "computers" or "mobileDevices"
	deviceType="$1"
	tmpFilePath="${tmpFileDir}/jss_temp_all_${deviceType}.json"
	rm -rf "$tmpFilePath"
	rm -rf "${tmpFileDir}/jss_temp_all_${deviceType}.xml"
	resultsPerPage=100
	resultsRetrived=0
	pageNumber=0
	totalIDsReturned=0
		resyncApiURL() {
			if [[ "$1" == "computers" ]]
			then
				if [[ "$useJPApiForFullIds_TF" == true ]]
				then
					proApiURL="${jss}/api/v1/computers-inventory?section=GENERAL&page=${pageNumber}&page-size=${resultsPerPage}&sort=id%3Aasc"
				else
					convertEpochTimestampToStandardOrRsql "rsql"
					proApiURL="${jss}/api/v1/computers-inventory?section=GENERAL&page=${pageNumber}&page-size=${resultsPerPage}&sort=id%3Aasc&filter=general.reportDate%3E%3D${rsqlDate}"
				fi
			else
				proApiURL="${jss}/api/v2/mobile-devices?page=${pageNumber}&page-size=${resultsPerPage}&sort=id%3Aasc"
			fi 
		}
	resyncApiURL "$deviceType"
	# make first api call to get full count of IDs and return the IDs according to limit per page set in $resultsPerPage
	curl -s -v $option "$auth" --header "Accept: application/json" -X GET "${proApiURL}" > "$tmpFilePath" 2> "$tmpResponseCode"
	checkApiResponseCode
	totalIDsReturned=$($jq -r .totalCount "$tmpFilePath")
	idArray=$($jq -r .results[].id "$tmpFilePath")
	resultsInArrayThisPage=$(echo "$idArray" | wc -l | tr -d " ")
	resultsRetrived=$((resultsRetrived + resultsInArrayThisPage))
	# report date is currently only available for computers using the Jamf Pro API
	if [[ "$useJPApiForFullIds_TF" == true ]]
	then
		reportDateArray=$($jq -r .results[].general.reportDate "$tmpFilePath")
		reportDateResultsInArrayThisPage=$(echo "$reportDateArray" | wc -l | tr -d " ")
		reportDateResultsRetrived=$((reportDateResultsRetrived + reportDateResultsInArrayThisPage))
	fi

	debugging "INFO: results returned [page ${pageNumber}, results retrieved = ${resultsRetrived} out of ${totalIDsReturned}]...."
		
	# the loop makes additional api calls to load the additional pages required to pull the inventory we are seeking for the $id variable
	while [[ $resultsRetrived -lt $totalIDsReturned ]]
	do
		rm -rf "$tmpFilePath"
		pageNumber=$((pageNumber + 1))
		resyncApiURL "$deviceType"
		curl -s -v $option "$auth" --header "Accept: application/json" -X GET "${proApiURL}" > "$tmpFilePath" 2> "$tmpResponseCode"
		checkApiResponseCode
		idArrayNextPage=$($jq -r .results[].id "$tmpFilePath")
		resultsInArrayThisPage=$(echo "$idArrayNextPage" | wc -l | tr -d " ") # how many devices on this page
		idArray=$(echo -e "${idArray}\n$idArrayNextPage")
		resultsRetrived=$((resultsRetrived + resultsInArrayThisPage))
		
		if [[ "$useJPApiForFullIds_TF" == true ]]
		then
			reportDateArrayNextPage=$($jq -r .results[].general.reportDate "$tmpFilePath")
			reportDateResultsInArrayThisPage=$(echo "$reportDateArrayNextPage" | wc -l | tr -d " ")
			reportDateArray=$(echo -e "${reportDateArray}\n$reportDateArrayNextPage")
			reportDateResultsRetrived=$((reportDateResultsRetrived + reportDateResultsInArrayThisPage))
		fi
		debugging "INFO: results returned [page ${pageNumber}, results retrieved = ${resultsRetrived} out of ${totalIDsReturned}]...."
	done	
	# once the loop is cleared, assign the contents of the array to $id
	id=$(echo "$idArray")
	# contents of reportDate key in JSON files (computers only)
	computerLastJamfReportDate=$(echo "$reportDateArray")
}

function checkMysqlErrors() {
	# This function looks for the exit code of the previous MySQL command and exits the script if it is not 0.
	errorStatus=$?
	mysQLErrorStatus=$(echo "mysql error status: $errorStatus" ) && debugging "$mysQLErrorStatus"
	
	if [[ "$errorStatus" != "0" ]]
	then
		##### mysql command returned an error
		echo "ERROR: There was an issue talking to the mysql database...." >> $logFilePath
		exit 1
	fi
	
	# if message is sent to $1, check it for mysql output containint "ERROR".  This will exit script in the case
	# where error code is 0 but script should exit (ex: user does not have access to database, credentials are incorrect, etc.)
	mysqlmessage=$(echo $1)
	if [[ "$mysqlmessage" =~ .*"ERROR".* ]]; then
		echo "ERROR: Exiting script due to an issue talking to the mysql database. Please check credentials for $jamfDBname...." >> $logFilePath
		exit 1
	fi
}

function debugging() {
	message=$1
	extraLogging=$2
	
	if [[ "$debugMode_TF" == true ]] && [[ "$message" != "" ]] && [[ "$extraLogging" == "" ]]
	then
		# log curl / mysql call output and other important info
		echo "DEBUG: ${message}" >> $logFilePath
	elif [[ "$debugMode_TF" == true ]] && [[ "$extraLogging" == "computers" ]] && [[ "$message" == "" ]] && [[ "$debugModeLogAllSyncedDataToTxtFiles_TF" == true ]]
	then
		##### logs the gathered computer info to a text file for troubleshooting
		echo "
		-----Write out the following for computer with ID $id-----
		serial number: $computers_serial_number
		asset tag: $computers_asset_tag
		operating system version: $computers_operating_system_version
		computer model: $computers_model
		building: $computers_building_name
		room: $computers_room
		department: $computers_department_name
		username: $computers_username
		last ip: $computers_last_ip
		computer name: $computers_computer_name
		MAC address: $computers_mac_address
		computer ID: $computers_computer_id
		PO number: $computers_po_number
		PO date epoch: $computers_po_date_epoch
		last report date: $computers_report_date_epoch
		warranty date epoch: $computers_warranty_date_epoch
		Extension Attributes (ID, name, type, multi-value TF, value)" >> "$logFileDir/$extraLogging-${now}.txt"
	elif [[ "$debugMode_TF" == true ]] && [[ "$extraLogging" == "mobileDevices" ]] && [[ "$message" == "" ]] && [[ "$debugModeLogAllSyncedDataToTxtFiles_TF" == true ]]
	then
		##### logs the gathered mobile device info to a text file for troubleshooting
		echo "
		-----Write out the following for device with ID $id-----
		asset tag: $mobile_devices_asset_tag
		mobile device ID: $mobile_devices_mobile_device_id
		model: $mobile_devices_model
		serial number: $mobile_devices_serial_number
		display name: $mobile_devices_display_name
		Wifi MAC address: $mobile_devices_wifi_mac_address
		IP address: $mobile_devices_ip_address
		OS version: $mobile_devices_os_version
		building: $mobile_devices_building_name
		room: $mobile_devices_room
		department: $mobile_devices_department_name
		username: $mobile_devices_username
		PO date epoch: $mobile_devices_po_date_epoch
		PO number: $mobile_devices_po_number
		last inventory update: $mobileLastJamfUpdateEpoch
		warranty date epoch: $mobile_devices_warranty_date_epoch
		model version number: $mobile_devices_model_version_number
		Extension Attributes (ID, name, type, multi-value TF, value)" >> "$logFileDir/$extraLogging-${now}.txt"
	fi
	
	if [[ "$debugMode_TF" == true ]] && [[ "$debugModeLogAllSyncedDataToTxtFiles_TF" == true ]] && [[ "$message" != "" ]] && [[ "$extraLogging" == "computers" || "$extraLogging" == "mobileDevices" ]]
	then
		##### logging the extension attribute data gathered from computer or mobile device, if it exists
		# spaced to allow for readability in formatting
		echo "			$message" >> "$logFileDir/$extraLogging-${now}.txt"
	fi	
}

function reportIdForExtensionAttributes() {
	# this function looks up an existing report_id for computer / device and if it doesn't exist in mysql, creates one
	# we then look up the report ID by computer / mobile device ID in order to assign EA values;
	# 
	# note that $1 shold be either "computer" or "mobile_device"
	# $2 is the $id of the computer / device in the current loop
	if [[ "$1" != "computer" ]] && [[ "$1" != "mobile_device" ]]
	then
		echo "ERROR: Incorrect parameter sent to reportIdForExtensionAttributes() function...." >> $logFilePath
		exit 1
	fi
	
	# check if report ID already exists for computer / device ID
	# returning the count of report ID row entries by computer / mobile device ID
	report_id_count=$($MYSQL --execute="select count(*) -1 as rowcount from reports where $1_id = $id;")
	if [[ $report_id_count -gt 0 ]]
	then
		debugging "INFO: multiple report IDs found for $1 with ID $id. Using most recent...."
		# using count returned from report_id_count, return only the last report ID
		report_id=$($MYSQL --execute="SELECT report_id from reports where $1_id = $id LIMIT $report_id_count, 1;")
	elif [[ $report_id_count -eq 0 ]]
	then
		# value of "0" indicates only one record exists so we will use the following query to return it
		report_id=$($MYSQL --execute="SELECT report_id from reports where $1_id = $id;")
	else
		# result of 0 or greater not returned, indicating there is no report ID for the computer/device
		report_id=""
	fi
	
	
	# if report_id comes back empty, set auto_increment (mysql will automatically assign report_id
	if [[ "$report_id" == "" ]]
	then
		$MYSQL --execute="insert into reports ($1_id) values ($id);"
		debugging "UPDATE: report_id not found for $1 with id $id...."
		report_id=$($MYSQL --execute="SELECT report_id from reports where $1_id = $id;")
		debugging "CREATE: created report_id $report_id for $1_id $id...."
	fi
	
	echo "$report_id"
}

function gatherExtensionAttributes() {
	deviceType="$1"
	if [[ "$deviceType" == "computers" ]]
	then
		computerOrMobile="computer"
		eaValueTable="extension_attribute_values"
	elif [[ "$deviceType" == "mobileDevices" ]]
	then
		computerOrMobile="mobile"
		eaValueTable="mobile_device_extension_attribute_values"
	else
		echo "ERROR: incorrect parameter sent to gatherExtensionAttributes() function"
		exit 1
	fi
	
	# check if parameter passed from reportIdForExtensionAttributes() is nil and if not, read EAs and write out to report_id
	if [[ "$2" != "" ]]
	then
		
		deletePreviousEaData=$($MYSQL --execute="delete from $eaValueTable where report_id = $2;")
		##### Get the number of occurances of extension attributes in the XML file #####
		nodeCount=$(cat "/tmp/jss_temp_${computerOrMobile}ID_$id.xml" | xmllint --xpath "count(//extension_attribute/id)" -)
		debugging "extension attributes found for $deviceType with id $id: $nodeCount"
		
		# Iterate the nodeset by index
		for i in $(seq 1 $nodeCount)
		do
			fullEA=$(cat "/tmp/jss_temp_${computerOrMobile}ID_$id.xml" | xmllint --xpath "concat((//extension_attribute)[$i]/id,', ',(//extension_attribute)[$i]/name, ', ',(//extension_attribute)[$i]/type, ', ',(//extension_attribute)[$i]/multi_value, ', ',(//extension_attribute)[$i]/value)" - ; echo) 
			
			debugging "$fullEA" "$deviceType"
			
			eaName=$(echo "$fullEA" | awk -F, '{print $2}'); eaType=$(echo "$fullEA" | awk -F, '{print $3}'); eaMultiValueTF=$(echo "$fullEA" | awk -F, '{print $4}');
			
			eaID=$(cat "/tmp/jss_temp_${computerOrMobile}ID_$id.xml" | xmllint --xpath "((//extension_attribute)[$i]/id)" - | sed -e 's/<[^>]*>//g'; echo)
			eaValue=$(cat "/tmp/jss_temp_${computerOrMobile}ID_$id.xml" | xmllint --xpath "((//extension_attribute)[$i]/value)" - | sed -e 's/<[^>]*>//g' | tr -d '\n'; echo)
			eaValue=$(escapeApostrophes "$eaValue")
			VALUES="('$eaID', '$eaValue', '$2')"
			
			if [[ "$deviceType" == "computers" ]]
			then
				# insert the extension attribute data into the extension_attribute_values table
				insertEaData=$($MYSQL --execute="INSERT INTO extension_attribute_values (extension_attribute_id, value_on_client, report_id) VALUES $VALUES;")
			else
				# insert the extension attribute data into the mobile_device_extension_attribute_values table
				insertEaData=$($MYSQL --execute="INSERT INTO mobile_device_extension_attribute_values (mobile_device_extension_attribute_id, value_on_client, report_id) VALUES $VALUES;")
			fi	
			eaDebugInsert=$(echo "INFO: inserted EAID: $eaID, report ID: $reportID, values: $eaValue....")
			debugging "$eaDebugInsert"
			
			# update names and extenaion attribute IDs in extension_attributes and mobile_device_extension_attributes tables
			syncExtensionAttributeNames "$deviceType" "$eaID" "$eaName"
			
		done
		
		# writing out the last_report_id to the computers_denormalized / mobile_devices_denormalized tables
		if [[ "$deviceType" == "computers" ]]
		then
			# UPDATE will be used here as a computer record will always exist for this id if this function runs
			updateReportID=$($MYSQL --execute="UPDATE computers_denormalized SET last_report_id = '$reportID' WHERE computer_id = $id;")
		else
			updateReportID=$($MYSQL --execute="UPDATE mobile_devices_denormalized SET last_report_id = '$reportID' WHERE mobile_device_id = $id;")
		fi
		
	else
		echo "ERROR: cannot write extension attributes to $deviceType with id $id, report_id missing...." >> $logFilePath
	fi
}

function syncExtensionAttributeNames() {
	# This function will sync EA names and extension_attribute_ids in the following tables: extenaion_attributes and mobile_device_extension_attributes.
	# This only needs to be done once per run on the computer and mobile device sides
	# $1 = deviceType
	# $2 = eaID
	# $3 = eaName
	if [[ "$1" == "computers" ]] && [[ "$refreshComputerEAnames" == true ]]
	then
		COLUMNS='(`extension_attribute_id`, `display_name`)'
		VALUES="('$2', '$3')"
		$MYSQL --execute="INSERT INTO extension_attributes $COLUMNS values $VALUES ON DUPLICATE KEY UPDATE display_name = '$3';"
		debugging "UPDATE: syncing EA names and IDs to extension_attribute table: EAID: $2, EAName: $3..."
	elif [[ "$1" == "mobileDevices" ]] && [[ "$refreshMobileDeviceEAnames" == true ]]
	then
		COLUMNS='(`mobile_device_extension_attribute_id`, `display_name`)'
		VALUES="('$2', '$3')"
		$MYSQL --execute="INSERT INTO mobile_device_extension_attributes $COLUMNS values $VALUES ON DUPLICATE KEY UPDATE display_name = '$3';"
		debugging "UPDATE: syncing EA names and IDs to mobile_device_extension_attribute table: EAID: $2, EAName: $3..."
	fi
}

function compareOldNewRecordsAndPerformdeleteBehavior() {
	#$1 must be either "computer" or "mobile_device"
	#######################################
	##### Begin compare old and new records
	##### Get the full list of computers / devices already in the target database to compare for delete behavior
	##### If ID exists in target database but not in source (computer / device was deleted) this will adjust record in target accordingly
	previousIDs=$($MYSQL --execute="select $1_id from $1s_denormalized;")
	##### The below loops will determine if a computer / device record needs to be deleted or marked according to delete behavior
	for previousID in ${previousIDs[@]}
	do
		idFound=false
		for currentID in ${id[@]}
		do
			if [[ "$previousID" == "$currentID" ]]
			then
				idFound=true
			fi
		done
		
		if [[ $idFound == false ]]
		then
			echo "INFO: $1 id $previousID found in target database but not in recent Jamfcloud data pull. Performing delete behavior to resolve outdated entry...." >> $logFilePath
			if [[ $deleteBehavior == "delete" ]]
			then
				echo "DELETE: deleting $1 id $previousID...." >> $logFilePath
				$MYSQL --execute="delete from $1s_denormalized where $1_id = $previousID;"
				if [[ "$1" == "computer" ]]
				then
					computersDeleted=$((computersDeleted + 1))
				elif [[ "$1" == "mobile_device" ]]
				then
					devicesDeleted=$((devicesDeleted + 1))
				fi

			elif [[ $deleteBehavior == "unmanage" ]]
			then
				echo "UPDATE: marking $1 id $previousID as unmanaged...." >> $logFilePath
				$MYSQL --execute="UPDATE $1s_denormalized SET is_managed = '0' WHERE $1_id = $previousID;"
				if [[ "$1" == "computer" ]]
				then
					computersUnmanaged=$((computersUnmanaged + 1))
				elif [[ "$1" == "mobile_device" ]]
				then
					devicesUnmanaged=$((devicesUnmanaged + 1))
				fi

			else 
				echo "INFO: no delete behavior selected, keeping $1 record with id $previousID as is...." >> $logFilePath
			fi
		fi
		
	done
}

function escapeApostrophes() {
	# This function escapes single quotes in variables to prevent mysql errors
	textToCheck="$1"
	if [[ "$textToCheck" = *"'"* ]] || [[ "$textToCheck" = *"’"* ]]
	then
		if [[ "$textToCheck" = *"’"* ]]
		then
			textToCheck=$(echo $textToCheck | sed -r "s/[’]+/'/g")
		fi
		textToCheck=$(echo $textToCheck | sed -e "s/'/\\\'/g" -e 's/"/\\"/g')
	fi
	echo "$textToCheck"
}

function convertManagedBool() {
	# This function simply converts true/false from Jamf to 0/1 for upload to mysql
	managedStatus="$1"

	if [[ "$managedStatus" == "true" ]]
	then
		managedStatus="1"
	elif [[ "$managedStatus" == "false" ]]
	then
		managedStatus="0"
	fi
	echo "$managedStatus"
}


function errorCheckInitialApiCalls() {
	##### Stops the script if computer /device IDs are not present in XML files (doesn't check http response code).  This will exit script,
	##### as well as prevent the deletion existing target database entries, if $deleteBehavior is set to "delete".
	if [[ "$id" == "" ]]
	then
		echo "ERROR: unable to proceed. Unable to retrieve XML records from $jss...." >> $logFilePath
		exit 1
	fi
}

function parseAndUploadComputerInfo() {
	if [[ "$efficiencyMode" == "" ]]
	then
		if [[ "$useJPApiForFullIds_TF" == true ]]
		then
			##### Get the full list of computers and parse JSON file for IDs
			getAllIdsByProApiFilter "computers"
		else
			##### Get the full list of computers and parse XML file for IDs
			id=$(echo 'cat //computer/id' | xmllint --shell "$tmpComputersAll" | tr -d "</>id-" | tr -d "\n\r")
			# using double parenthasis for computerLastJamfUpdateEpoch to allow for accessing array indexes 
			computerLastJamfUpdateEpoch=($(echo 'cat //computer/report_date_epoch' | xmllint --shell "$tmpComputersAll" | tr -d "</>report_date_epoch-" | tr -d "\n\r"))
		fi
		errorCheckInitialApiCalls 	
		#######################################
		##### Begin compare old and new records
		##### Must use the full list of computers in Jamf Pro to compare with MySQL for delete behavior
		compareOldNewRecordsAndPerformdeleteBehavior "computer"
		##### End compare old and new records 
		#######################################
	elif [[ "$efficiencyMode" == "search" ]] && [[ -f "$lastSyncFile" ]]
	then
		# overwrite the existing temp file with Advanced Somputer Search XML showing only computers IDs for computers that have updated since last script sync
		getAllIdsByAdvancedSearch "computers"
		id=$(echo 'cat //advanced_computer_search/computers/computer/id' | xmllint --shell "$tmpComputersAll" | tr -d "</>id-" | tr -d "\n\r")
		names=($(echo 'cat //advanced_computer_search/computers/computer/Computer_Name' | xmllint --shell "$tmpComputersAll" | tr -d "</>id-" | tr -d "\n\r"))
		# the below returns the count of computer IDs in the Advanced Computer Search which have updated their info in Jamf since $standardDate
		computerIdsToCount=$(cat $tmpComputersAll | xmllint --xpath "count(//advanced_computer_search/computers/computer/id)" -)
		echo "INFO: Advanced Computer Search found $computerIdsToCount computer(s) that have updated Jamf records since $standardDate...." >> $logFilePath
		errorCheckInitialApiCalls
		# since we are only creating an Advanced Computer Search based on date, we will now feed the IDs generated above
		# through the normal workflow to compare timestamps before updating
	elif [[ "$efficiencyMode" == "filter" ]] && [[ -f "$lastSyncFile" ]]
	then	
		getAllIdsByProApiFilter "computers"
		# run the convert timestamp function to retrieve the standard readable date
		convertEpochTimestampToStandardOrRsql ""
		echo "INFO: Efficiency Mode filter found $totalIDsReturned computer(s) that have updated Jamf records since $standardDate...." >> $logFilePath
	else
		echo "ERROR: invalid option chosen...." >> $logFilePath
		exit 1
	fi
	
	echo "INFO: Performing timestamp comparison to determine which results need updating...." >> $logFilePath
	echo "SYNC: Beginning computer record sync...." >> $logFilePath
	#############################################################
	# if using Jamf Pro API, convert timestamp from JSON to epoch
	if [[ "$useJPApiForFullIds_TF" == true ]]
	then
		computerLastJamfReportDate=($computerLastJamfReportDate)
		for reportDate in ${computerLastJamfReportDate[@]}
		do
			if [[ "$reportDate" == "null" ]]
			then
				epoch="000"
			else
				if [[ "$ubuntuCheck" == "" ]]
				then
					reportDateFormatted=$(echo "$reportDate" | awk -F. '{print $1}' | awk '{gsub("T", " ");print}' | tr -d "Z")
					epoch="$(date -j -u -f "%Y-%m-%d %T" "${reportDateFormatted}" "+%s")000"
				else
					epoch="$(date -d "$reportDate" +%s)000"
				fi
			fi
			convertedDates=$(echo -e "$convertedDates\n$epoch")
		done
		computerLastJamfUpdateEpoch=($( echo $convertedDates))
	fi
	#############################################################
	# gets the computerLastJamfUpdateEpoch index corresponding with the computer ID currently being looped through
	arrayIndex=0
	for id in ${id[@]}
	do		
		##### Determine if source record is recent enough to be updated in target database
		if [[ "$lastSyncEpoch" -gt "${computerLastJamfUpdateEpoch[$arrayIndex]}" ]] && [[ -f "$lastSyncFile" ]]
		then
			skipMessage=$(echo "INFO: skipping sync for computer with ID: $id - last db sync: $lastSyncEpoch last jamf update: ${computerLastJamfUpdateEpoch[$arrayIndex]}") && debugging "$skipMessage"
			arrayIndex=$((arrayIndex + 1))
		else
			arrayIndex=$((arrayIndex + 1))
			####################################################
			##### Get computer record by id then set data points
			checkTokenTimeout
			curl -s -v $option "$auth" "$jss/JSSResource/computers/id/$id" -X GET -H "accept: application/xml" > "/tmp/jss_temp_computerID_$id.xml" 2> "$tmpResponseCode"
			checkApiResponseCode
			# Use xmllint to to set variables based on XML tags
			computers_serial_number=$(xmllint --xpath "string(//serial_number)" "/tmp/jss_temp_computerID_$id.xml")
			computers_asset_tag=$(xmllint --xpath "string(//asset_tag)" "/tmp/jss_temp_computerID_$id.xml")
			computers_operating_system_version=$(xmllint --xpath "string(//os_version)" "/tmp/jss_temp_computerID_$id.xml") 
			computers_model=$(xmllint --xpath "string(//model)" "/tmp/jss_temp_computerID_$id.xml") 
			computers_building_name=$(xmllint --xpath "string(//building)" "/tmp/jss_temp_computerID_$id.xml") 
			computers_room=$(xmllint --xpath "string(//room)" "/tmp/jss_temp_computerID_$id.xml") 
			computers_department_name=$(xmllint --xpath "string(//department)" "/tmp/jss_temp_computerID_$id.xml") 
			computers_username=$(xmllint --xpath "string(//username)" "/tmp/jss_temp_computerID_$id.xml") 
			computers_last_ip=$(xmllint --xpath "string(//last_reported_ip)" "/tmp/jss_temp_computerID_$id.xml") 
			computers_mac_address=$(xmllint --xpath "string(//mac_address)" "/tmp/jss_temp_computerID_$id.xml") 
			computers_computer_id=$(xmllint --xpath "string(//id)" "/tmp/jss_temp_computerID_$id.xml") 
				if [[ "$computers_computer_id" =~ [^[:digit:]] ]] || [[ "$computers_computer_id" == "" ]]
				then
					echo "ERROR: computer ID returned with non-numerical or empty value [$computers_computer_id] - reverting to ID found in JSON parse [$id]" >> "$logFilePath"
					computers_computer_id="$id"
				fi
			computers_po_number=$(xmllint --xpath "string(//po_number)" "/tmp/jss_temp_computerID_$id.xml") 
			computers_po_date_epoch=$(xmllint --xpath "string(//po_date_epoch)" "/tmp/jss_temp_computerID_$id.xml") 
			computers_warranty_date_epoch=$(xmllint --xpath "string(//warranty_expires_epoch)" "/tmp/jss_temp_computerID_$id.xml") 
			computers_computer_name=$(xmllint --xpath "string(//name)" "/tmp/jss_temp_computerID_$id.xml") 
			computers_report_date_epoch=$(xmllint --xpath "string(//report_date_epoch)" "/tmp/jss_temp_computerID_$id.xml")
			computers_is_managed=$(xmllint --xpath "string(//managed)" "/tmp/jss_temp_computerID_$id.xml") 
			##### convert computer management status to mysql-readable
			computers_is_managed=$(convertManagedBool "$computers_is_managed")
			##### escape apostrophes in computer names
			computers_computer_name=$(escapeApostrophes "$computers_computer_name")
			# write Jamf computer records to /tmp/computers.txt if debugging enabled (excluding extension attributes, which are added below)
			debugging "" "computers"
			##### End get computer record by id then set data points #####
			##############################################################
			
			########################################
			##### start mysql table formatting #####
			########################################
			# columns to insert into for computers_denomralized 
			COLUMNS='(`computer_id`, `computer_name`, `asset_tag`, `last_ip`, `username`, `department_name`, `building_name`, `room`, `model`, `mac_address`, `serial_number`, `operating_system_version`, `po_number`, `po_date_epoch`, `last_report_date_epoch`, `is_managed`)'
			
			# selected values gathered from API calls inserted into columns
			VALUES="('$computers_computer_id', '$computers_computer_name', '$computers_asset_tag', '$computers_last_ip', '$computers_username', '$computers_department_name', '$computers_building_name', '$computers_room', '$computers_model', '$computers_mac_address', '$computers_serial_number', '$computers_operating_system_version', '$computers_po_number', '$computers_po_date_epoch', '$computers_report_date_epoch', '$computers_is_managed')"
			######################################
			##### end mysql table formatting #####
			######################################
	
			##### Check if computer record exists in database
			computerIDcheck=$($MYSQL --execute="select count(*) from computers_denormalized where computer_id = $id;")
			# 0 for not found, 1 for found
			checkMysqlErrors 
			computerRecordMsg=$(echo "computer ID $id record count: $computerIDcheck") && debugging "$computerRecordMsg"
	
			if [[ "$computerIDcheck" == "1" ]]
			then
				echo "UPDATE: computer found, updating record for computer_id $id" >> "$logFilePath"
				# mysql update existing record
				$MYSQL --execute="UPDATE computers_denormalized SET serial_number = '$computers_serial_number', asset_tag = '$computers_asset_tag', operating_system_version='$computers_operating_system_version', model = '$computers_model', building_name = '$computers_building_name', room = '$computers_room', department_name = '$computers_department_name', username = '$computers_username', last_ip = '$computers_last_ip', computer_name = '$computers_computer_name', mac_address = '$computers_mac_address', computer_id = '$computers_computer_id', po_number = '$computers_po_number', po_date_epoch = '$computers_po_date_epoch', warranty_date_epoch = '$computers_warranty_date_epoch', last_report_date_epoch = '$computers_report_date_epoch', is_managed = '$computers_is_managed' WHERE computer_id = $id;" 
				computersUpdated=$((computersUpdated + 1))
			elif [[ "$computerIDcheck" == "0" ]]
			then
				echo "CREATE: computer not found, creating record for computer_id $id" >> "$logFilePath"
				# mysql insert new record
				$MYSQL --execute="INSERT INTO computers_denormalized $COLUMNS VALUES $VALUES;"
				computersCreated=$((computersCreated + 1))
			else
				echo "ERROR: multiple records were found for computers_denormalized.computer_id = $id" >> $logFilePath
				exit 1
			fi
			########################################
			##### Collect Extension Attributes #####
			if [[ "$syncComputerExtensionAttributes_TF" == true ]]
			then
				reportID=$(reportIdForExtensionAttributes "computer")
				gatherExtensionAttributes  "computers" "$reportID"
				refreshComputerEAnames=false  
			fi
			##### End collect extension attributes #####
			############################################
			#########################################
			rm -rf "/tmp/jss_temp_computerID_$id.xml"
			#########################################
			if [[ "$testMode_TF" == true ]]
			then
				return 
			fi
		fi
	done
	echo "-------------------" >> "$logFilePath"
	echo "SUCCESS: MySQL data for computers_denormalized successfully updated...." >> $logFilePath
	echo "-------------------" >> "$logFilePath"

}

function parseAndUploadMobileDeviceInfo() {	
	if [[ "$efficiencyMode" == "" ]]
	then
		if [[ "$useJPApiForFullIds_TF" == true ]]
		then
			##### Get the full list of mobile devices and parse JSON file for IDs
			getAllIdsByProApiFilter "mobiledevices"
		else
			##### Get the full list of mobile devices and parse XML file for IDs
			id=$(echo 'cat //mobile_device/id' | xmllint --shell "$tmpDevicesAll" | tr -d "</>id-" | tr -d "\n\r")
		fi
		errorCheckInitialApiCalls
		#######################################
		##### Begin compare old and new records
		compareOldNewRecordsAndPerformdeleteBehavior "mobile_device"
		##### End compare old and new records 
		#######################################
	elif [[ "$efficiencyMode" == "search" ]] && [[ -f "$lastSyncFile" ]]
	then
		# overwrite the existing temp file with Advanced Somputer Search XML showing only computers IDs for computers that have updated since last script sync
		getAllIdsByAdvancedSearch "mobiledevices"
		id=$(echo 'cat //advanced_mobile_device_search/mobile_devices/mobile_device/id' | xmllint --shell "$tmpDevicesAll" | tr -d "</>id-" | tr -d "\n\r")
		# the below returns the count of computer IDs in the Advanced Computer Search which have updated their info in Jamf since $standardDate
		deviceIdsToCount=$(cat $tmpDevicesAll | xmllint --xpath "count(//advanced_mobile_device_search/mobile_devices/mobile_device/id)" -)
		echo "INFO: Advanced Mobile Device Search found $deviceIdsToCount mobile device(s) that have updated Jamf records since $standardDate...." >> $logFilePath
		errorCheckInitialApiCalls
		# since we are only creating an Advanced Computer Search based on date, we will now feed the IDs generated above
		# through the normal workflow to compare timestamps before updating
	elif [[ "$efficiencyMode" == "filter" ]] && [[ -f "$lastSyncFile" ]]
	then	
		getAllIdsByProApiFilter "mobiledevices"
	else
		echo "ERROR: invalid option chosen...." >> $logFilePath
		exit 1
	fi
	
	echo "INFO:: Performing timestamp comparison to determine which results need updating...." >> $logFilePath
	echo "SYNC: Beginning mobile device record sync...." >> $logFilePath
	
	for id in ${id[@]}
	do
		checkTokenTimeout
		curl -s -v $option "$auth" "$jss/JSSResource/mobiledevices/id/$id" -X GET -H "accept: application/xml" > "/tmp/jss_temp_mobileID_$id.xml" 2> "$tmpResponseCode"
		checkApiResponseCode
		
		# since JSSResource/mobiledevices doesn't have the /subset/basic option as with Computers (and JPAPI api/v2/mobile-devices deosn't show 
		# report date like it does for # computers), we have to still make 1 API call per ID to pull all the details and first determine if it 
		# should be updated based on last last_inventory_update_epoch
		mobileLastJamfUpdateEpoch=$(xmllint --xpath "string(//last_inventory_update_epoch)" "/tmp/jss_temp_mobileID_$id.xml")
				
		##### Determine if source record is recent enough to be updated in target database
		if [[ $lastSyncEpoch -gt $mobileLastJamfUpdateEpoch ]] && [[ -f "$lastSyncFile" ]]
		then
			skipMessage=$(echo "INFO: skipping sync for mobile device with ID: $id - last db sync: $lastSyncEpoch last jamf update: ${mobileLastJamfUpdateEpoch}") && debugging "$skipMessage"
			rm -rf "/tmp/jss_temp_mobileID_$id.xml"
		else
			#########################################################
			##### Get mobile device record by id then set data points
			mobile_devices_asset_tag=$(xmllint --xpath "string(//asset_tag)" "/tmp/jss_temp_mobileID_$id.xml")
			mobile_devices_mobile_device_id=$(xmllint --xpath "string(//id)" "/tmp/jss_temp_mobileID_$id.xml")
				if [[ "$mobile_devices_mobile_device_id" =~ [^[:digit:]] ]] || [[ "$mobile_devices_mobile_device_id" == "" ]]
				then
					echo "ERROR: mobile device ID returned with non-numerical or empty value [$mobile_devices_mobile_device_id] - reverting to ID found in JSON parse [$id]" >> "$logFilePath"
					mobile_devices_mobile_device_id="$id"
				fi
			mobile_devices_model=$(xmllint --xpath "string(//model)" "/tmp/jss_temp_mobileID_$id.xml")
			mobile_devices_serial_number=$(xmllint --xpath "string(//serial_number)" "/tmp/jss_temp_mobileID_$id.xml")
			mobile_devices_wifi_mac_address=$(xmllint --xpath "string(//wifi_mac_address)" "/tmp/jss_temp_mobileID_$id.xml")
			mobile_devices_ip_address=$(xmllint --xpath "string(//ip_address)" "/tmp/jss_temp_mobileID_$id.xml")
			mobile_devices_os_version=$(xmllint --xpath "string(//os_version)" "/tmp/jss_temp_mobileID_$id.xml")
			mobile_devices_building_name=$(xmllint --xpath "string(//building)" "/tmp/jss_temp_mobileID_$id.xml")
			mobile_devices_room=$(xmllint --xpath "string(//building)" "/tmp/jss_temp_mobileID_$id.xml")
			mobile_devices_department_name=$(xmllint --xpath "string(//room)" "/tmp/jss_temp_mobileID_$id.xml")
			mobile_devices_username=$(xmllint --xpath "string(//username)" "/tmp/jss_temp_mobileID_$id.xml")
			mobile_devices_po_date_epoch=$(xmllint --xpath "string(//po_date_epoch)" "/tmp/jss_temp_mobileID_$id.xml")
			mobile_devices_po_number=$(xmllint --xpath "string(//po_number)" "/tmp/jss_temp_mobileID_$id.xml")
			mobile_devices_warranty_date_epoch=$(xmllint --xpath "string(//warranty_expires_epoch)" "/tmp/jss_temp_mobileID_$id.xml")
			mobile_devices_model_version_number=$(xmllint --xpath "string(//model_number)" "/tmp/jss_temp_mobileID_$id.xml")
			mobile_devices_display_name=$(xmllint --xpath "string(//device_name)" "/tmp/jss_temp_mobileID_$id.xml")
			mobile_devices_is_managed=$(xmllint --xpath "string(//managed)" "/tmp/jss_temp_mobileID_$id.xml")
			##### convert mobile device management status to mysql-readable
			mobile_devices_is_managed=$(convertManagedBool "$mobile_devices_is_managed")
			##### escape apostrophes in mobile device names
			mobile_devices_display_name=$(escapeApostrophes "$mobile_devices_display_name")
			# write Jamf mobile device records to /tmp/mobileDevices.txt if debugging enabled
			debugging "" "mobileDevices"
			##### End get mobile device record by id then set data points #####
			###################################################################
			
			########################################
			##### start mysql table formatting #####
			########################################		
			# columns to insert into for mobile_devices_denomralized 
			COLUMNS='(`mobile_device_id`, `display_name`, `asset_tag`, `wifi_mac_address`, `serial_number`, `ip_address`, `model`, `model_version_number`, `os_version`, `username`, `department_name`, `building_name`, `room`, `po_number`, `po_date_epoch`, `warranty_date_epoch`, `last_report_date_epoch`, `is_managed`)'
			
			# selected values gathered from API calls inserted into columns
			VALUES="('$mobile_devices_mobile_device_id', '$mobile_devices_display_name', '$mobile_devices_asset_tag', '$mobile_devices_wifi_mac_address', '$mobile_devices_serial_number', '$mobile_devices_ip_address', '$mobile_devices_model', '$mobile_devices_model_version_number', '$mobile_devices_os_version', '$mobile_devices_username', '$mobile_devices_department_name', '$mobile_devices_building_name', '$mobile_devices_room', '$mobile_devices_po_number', '$mobile_devices_po_date_epoch', '$mobile_devices_warranty_date_epoch', '$mobileLastJamfUpdateEpoch', '$mobile_devices_is_managed')"
			######################################
			##### end mysql table formatting #####
			######################################
			##### Check if computer record exists in database
			mobileDeviceIDcheck=$($MYSQL --execute="select count(*) from mobile_devices_denormalized where mobile_device_id = $id;")			
			checkMysqlErrors
			mobileDeviceRecordMsg=$(echo "mobile device ID $id record count: $mobileDeviceIDcheck") && debugging "$mobileDeviceRecordMsg"
			
			if [[ "$mobileDeviceIDcheck" == "1" ]]
			then
				echo "UPDATE: mobile device found, updating record for mobile_device_id $id" >> "$logFilePath"
				# mysql update existing record
				$MYSQL --execute="UPDATE mobile_devices_denormalized SET mobile_device_id = '$mobile_devices_mobile_device_id', display_name = '$mobile_devices_display_name', asset_tag ='$mobile_devices_asset_tag', wifi_mac_address = '$mobile_devices_wifi_mac_address', serial_number = '$mobile_devices_serial_number', ip_address = '$mobile_devices_ip_address', model = '$mobile_devices_model', model_version_number = '$mobile_devices_model_version_number', os_version = '$mobile_devices_os_version', username = '$mobile_devices_username', department_name = '$mobile_devices_department_name', building_name = '$mobile_devices_building_name', room = '$mobile_devices_room', po_number = '$mobile_devices_po_number', po_date_epoch = '$mobile_devices_po_date_epoch', warranty_date_epoch = '$mobile_devices_warranty_date_epoch', last_report_date_epoch = '$mobileLastJamfUpdateEpoch', is_managed = '$mobile_devices_is_managed' WHERE mobile_device_id = $id;"
				devicesUpdated=$((devicesUpdated + 1))
			elif [[ "$mobileDeviceIDcheck" == "0" ]]
			then
				echo "CREATE: mobile device not found, creating record for mobile_device_id $id" >> "$logFilePath"
				# mysql insert new record
				$MYSQL --execute="INSERT INTO mobile_devices_denormalized $COLUMNS VALUES $VALUES;"
				devicesCreated=$((devicesCreated + 1))
			else
				echo "ERROR: multiple records were found for mobile_devices_denormalized.computer_id = $id" >> $logFilePath
				exit 1
			fi
			########################################
			##### Collect Extension Attributes #####
			if [[ "$syncMobileDeviceExtensionAttributes_TF" == true ]]
			then
				reportID=$(reportIdForExtensionAttributes "mobile_device")
				gatherExtensionAttributes  "mobileDevices" "$reportID"
				refreshMobileDeviceEAnames=false
			fi
			##### End collect extension attributes #####
			############################################
			#######################################
			rm -rf "/tmp/jss_temp_mobileID_$id.xml"
			#######################################
			if [[ "$testMode_TF" == true ]]
			then
				return 
			fi
		fi
	done
	echo "-------------------" >> "$logFilePath"
	echo "SUCCESS: MySQL data for mobile_devices_denormalized successfully updated...." >> $logFilePath
	echo "-------------------" >> "$logFilePath"

}

function cleanUp() {
	# Cleanup the mess
	rm -rf /tmp/jss_temp*
}
					
function summarizeTables() {
	dbCountTimeline=$1
	# converting output of MySQL commands to stdout and stderr then sending to debugging() function for logging, if enabled.
	# the variables below also need to be converted back to their stdout values before using 
	if [[ "$dbCountTimeline" == "previous" ]]
	then
		echo "Reading existing entries in target database [$jamfDBname]...." >> $logFilePath
		totalCurrentComputersInMysql=$($MYSQL --execute="select count(*) from computers_denormalized;" 2>&1)
			debugging "computers in mysql at script start: ${totalCurrentComputersInMysql}"
			# stop script if mysql credentials are incorrect or db unreachable
			checkMysqlErrors "${totalCurrentComputersInMysql}"

		totalCurrentDevicesInMysql=$($MYSQL --execute="select count(*) from mobile_devices_denormalized;" 2>&1)
			debugging "devices in mysql at script start: ${totalCurrentDevicesInMysql}"
			# stop script if mysql credentials are incorrect or db unreachable
			checkMysqlErrors "${totalCurrentDevicesInMysql}"		
	else
		echo "Summarizing entries in target database...." >> $logFilePath
		totalNewComputersInMysql=$($MYSQL --execute="select count(*) from computers_denormalized;" 2>&1)
			debugging "computers in mysql at script end: ${totalNewComputersInMysql}"
		totalNewDevicesInMysql=$($MYSQL --execute="select count(*) from mobile_devices_denormalized;" 2>&1)
			debugging "devices in mysql at script end: ${totalNewDevicesInMysql}"
		
		totalComputersUnmanaged=$($MYSQL --execute="select count(*) from computers_denormalized where is_managed = 0;" 2>&1)
			debugging "all unmanaged computers: ${totalComputersUnmanaged}"
		totalDevicesUnmanaged=$($MYSQL --execute="select count(*) from mobile_devices_denormalized where is_managed = 0;" 2>&1)
		debugging "all unmanaged devices: ${totalDevicesUnmanaged}"
	fi	
}
					
function scriptDuration() {
	startOrStop=$1

	if [[ "$startOrStop" == "start" ]]
	then
		startScriptEpochSeconds="$(date +%s)"
	elif [[ "$startOrStop" == "stop" ]];
	then
		stopScriptEpochSeconds="$(date +%s)"
		durationInSeconds=$((stopScriptEpochSeconds-startScriptEpochSeconds))
		day=0; hour=0; min=0; sec=0
		
		if ((durationInSeconds>59))
		then
			((sec=durationInSeconds%60))
			((durationInSeconds=durationInSeconds/60))
			if ((durationInSeconds>59))
			then
				((min=durationInSeconds%60))
				((durationInSeconds=durationInSeconds/60))
				if ((durationInSeconds>23)) 
				then
					((hour=durationInSeconds%24))
					((day=durationInSeconds/24))
				else
					((hour=durationInSeconds))
				fi
			else
				((min=durationInSeconds))
			fi
		else
			((sec=durationInSeconds))
		fi
		
		echo "Script duration: $day day(s) $hour hour(s) $min minute(s) $sec second(s)" >> $logFilePath
		echo "Script running complete...."
	fi
}
					
function checkApiResponseCode() {
	# retrieves the http response code from the previous Jamfcloud api (stored in /tmp/jss_temp_response_code.txt) call and provides action based on error status
	responseCode=$(cat "${tmpFileDir}/jss_temp_response_code.txt" | grep "< HTTP/2" | awk '{print $3}') 
	APBALANCEID=$(cat "${tmpFileDir}/jss_temp_response_code.txt" | grep "APBALANCEID" | awk '{print $3}' | tr -d ";")
	# send $1 to function if we want to retry a call that had an error code
	retry="$1"
	
	response=$(echo "INFO: Jamfcloud response code: [$responseCode]")
	debugging "$response"
		
	case "$responseCode" in
		"401")
			echo "ERROR: user unable to authenticate to $jss. Please check credentials...." >> "$logFilePath"
			scriptDuration "stop"
			exit 1
		;;
		"404")
			echo "ERROR: $jss not found...." >> "$logFilePath"
			if [[ "$retry" != "retry" ]]
			then
				scriptDuration "stop"
				exit 1
			fi
		;;
		"403")
			echo "ERROR: access to $jss forbidden by server. Check permissions and try again...." >> "$logFilePath"
			scriptDuration "stop"
			exit 1
		;;
		"408")
			echo "ERROR: request timed out to $jss...." >> "$logFilePath"
			scriptDuration "stop"
			exit 1
		;;
		"400")
			echo "ERROR: bad request to $jss...." >> "$logFilePath"
			scriptDuration "stop"
			exit 1
		;;
		"201")
			debugging "INFO: temp Advanced Search created successfully on $jss...."
		;;
		"200")
			#[OK]
		;;
		"")
			# if code returns as nil, exit with unknown error
			echo "ERROR: unknown error. Unable to reach $jss...." >> "$logFilePath"
			scriptDuration "stop"
			exit 1
		;;
		default)
			# if code returns different from entries above, log error but attempt to continue
			echo "ERROR: unknown error communicating with $jss [check response code]. Attempting to continue...." >> "$logFilePath"
		;;
	esac
	
	rm -rf "$tmpResponseCode"
}
					
function firstRunCreateDbTables() {
	
	if [[ -f "$lastSyncFile" ]]
	then
		echo ""
	else
		
		echo "CREATE: sync file not found. Creating database tables, if not already created...." >> $logFilePath
		createExtensionAttributeValuesTable=$($MYSQL --execute="CREATE TABLE IF NOT EXISTS extension_attribute_values (extension_attribute_id int(11) NOT NULL DEFAULT '-1', report_id int(11) NOT NULL DEFAULT '-1', value_on_client longtext COLLATE utf8_unicode_ci, date_value_epoch bigint(32) NOT NULL DEFAULT '0', id bigint(32) NOT NULL AUTO_INCREMENT, PRIMARY KEY (id), KEY report_id (report_id), KEY report_id_extension_attribute_id (report_id, extension_attribute_id)) ENGINE=InnoDB AUTO_INCREMENT=180475 DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;" 2>&1)
		debugging "table: extension_attribute_values ${createExtensionAttributeValuesTable}" && checkMysqlErrors
		
		createMobileDeviceExtensionAttributeValuesTable=$($MYSQL --execute="CREATE TABLE IF NOT EXISTS mobile_device_extension_attribute_values (mobile_device_extension_attribute_id int(11) NOT NULL DEFAULT '-1', report_id int(11) NOT NULL DEFAULT '-1', value_on_client longtext COLLATE utf8_unicode_ci, date_value_epoch bigint(32) NOT NULL DEFAULT '0', id bigint(32) NOT NULL AUTO_INCREMENT, PRIMARY KEY (id), KEY report_id (report_id), KEY mdea_report_id_mdea_id_value_on_client (mobile_device_extension_attribute_id,value_on_client(25),report_id)) ENGINE=InnoDB AUTO_INCREMENT=700082 DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;" 2>&1)
		debugging "table: mobile_device_extension_attribute_values ${createMobileDeviceExtensionAttributeValuesTable}" && checkMysqlErrors

		createReportsTable=$($MYSQL --execute="CREATE TABLE IF NOT EXISTS reports (report_id int(11) NOT NULL AUTO_INCREMENT, computer_id int(11) NOT NULL DEFAULT '0', mobile_device_id int(11) NOT NULL DEFAULT '0', user_object_id int(11) NOT NULL DEFAULT '0', date_entered_epoch bigint(32) NOT NULL DEFAULT '0', total_seconds int(11) NOT NULL DEFAULT '0', in_process tinyint(1) NOT NULL DEFAULT '0', PRIMARY KEY (report_id), KEY computer_id (computer_id), KEY mobile_device_id (mobile_device_id), KEY user_object_id (user_object_id), KEY date_entered_epoch (date_entered_epoch), KEY in_process (in_process)) ENGINE=InnoDB AUTO_INCREMENT=130160 DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;" 2>&1)
		debugging "table: reports ${createReportsTable}" && checkMysqlErrors
		
		createComputersDenormalizedTable=$($MYSQL --execute="CREATE TABLE IF NOT EXISTS computers_denormalized (computer_id int(11) NOT NULL DEFAULT '-1', computer_name varchar(60) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', udid varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', management_id varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', 	last_report_id int(11) NOT NULL DEFAULT '-1', asset_tag varchar(40) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', platform varchar(20) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', bar_code_1 varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', bar_code_2 varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', 	last_contact_time_epoch bigint(32) NOT NULL DEFAULT '0', last_report_date_epoch bigint(32) NOT NULL DEFAULT '0', last_cloud_backup_date_epoch bigint(32) NOT NULL DEFAULT '0', last_enrolled_date_epoch bigint(32) NOT NULL DEFAULT '0', is_managed tinyint(1) NOT NULL DEFAULT '0', management_username varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', jamf_binary_version varchar(100) COLLATE utf8_unicode_ci NOT NULL DEFAULT 'n/a', last_ip varchar(40) COLLATE utf8_unicode_ci NOT NULL DEFAULT '' COMMENT '[PII]', last_reported_ip varchar(40) COLLATE utf8_unicode_ci NOT NULL DEFAULT '' COMMENT '[PII]', last_location_id int(11) NOT NULL DEFAULT '-1', username varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '' COMMENT '[PII]', realname varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '' COMMENT '[PII]', email varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '' COMMENT '[PII]', department_id int(11) NOT NULL DEFAULT '-1', building_id int(11) NOT NULL DEFAULT '-1', department_name varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '' COMMENT '[PII]', building_name varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '' COMMENT '[PII]', room varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '' COMMENT '[PII]', phone varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '' COMMENT '[PII]', position varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '' COMMENT '[PII]', make varchar(100) COLLATE utf8_unicode_ci NOT NULL DEFAULT 'Apple', model varchar(60) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', model_identifier varchar(60) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', 	mac_address varchar(20) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', network_adapter_type varchar(40) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', 	alt_mac_address varchar(20) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', alt_network_adapter_type varchar(40) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', nic_speed varchar(20) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', optical_drive varchar(100) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', boot_rom varchar(64) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', bus_speed_mhz bigint(32) NOT NULL DEFAULT '-1', serial_number varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', processor_speed_mhz bigint(32) NOT NULL DEFAULT '-1', processor_count int(2) NOT NULL DEFAULT '-1', core_count int(2) NOT NULL DEFAULT '-1', processor_type varchar(60) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', processor_architecture varchar(60) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', total_ram_mb bigint(32) NOT NULL DEFAULT '-1', open_ram_slots int(11) NOT NULL DEFAULT '-1', smc_version varchar(20) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', battery_capacity int(11) NOT NULL DEFAULT '0', file_vault_1_status varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '' COMMENT 'This is FV1 and FV2 user status', file_vault_1_status_percent int(11) NOT NULL DEFAULT '-1' COMMENT 'This is FV1 and FV2 user status', file_vault_2_status varchar(50) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', file_vault_2_recovery_key_type varchar(50) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', file_vault_2_recovery_key_valid tinyint(1) NOT NULL DEFAULT '3' COMMENT 'Maps to file_vault_2_computer_key.individual_key_verified', file_vault_2_institutional_key_present tinyint(1) NOT NULL DEFAULT '0' COMMENT 'Maps to file_vault_2_computer_key.institutional_key_present', file_vault_2_eligibility_message varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '' COMMENT 'Maps to computers.file_vault_2_eligibility_message', disk_encryption_configuration varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', hard_drive_size_mb bigint(32) NOT NULL DEFAULT '-1', smart_status varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', lvm_managed_boot_partition tinyint(1) NOT NULL DEFAULT '0', 	boot_drive_percent_full int(11) NOT NULL DEFAULT '-1', boot_drive_available_mb bigint(32) NOT NULL DEFAULT '-1', operating_system_name varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', operating_system_version varchar(30) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', operating_system_build varchar(30) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', operating_system_comparable int(11) NOT NULL DEFAULT '0', service_pack varchar(64) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', master_password_set tinyint(1) NOT NULL DEFAULT '0', active_directory_status varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT 'N/A', number_of_available_updates tinyint(1) NOT NULL DEFAULT '0', applecare_id varchar(60) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', po_number varchar(60) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', vendor varchar(60) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', leased tinyint(1) NOT NULL DEFAULT '0', purchased tinyint(1) NOT NULL DEFAULT '0', lease_date_epoch bigint(32) NOT NULL DEFAULT '0', po_date_epoch bigint(32) NOT NULL DEFAULT '0', warranty_date_epoch bigint(32) NOT NULL DEFAULT '0', purchase_price varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', life_expectancy int(11) NOT NULL DEFAULT '0', purchasing_account varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', purchasing_contact varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', ble_capable tinyint(1) NOT NULL DEFAULT '0', sip_status tinyint(1) NOT NULL DEFAULT '0', gatekeeper_status tinyint(1) NOT NULL DEFAULT '0', xprotect_version varchar(20) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', auto_login_user varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', mdm_capability tinyint(1) NOT NULL DEFAULT '0', 	itunes_store_account_is_active tinyint(1) NOT NULL DEFAULT '0', itunes_store_account_hash varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', device_certificate_expiration bigint(32) NOT NULL DEFAULT '-1', mdm_certificate_expiration bigint(32) NOT NULL DEFAULT '-1', enrolled_via_automated_device_enrollment tinyint(1) NOT NULL DEFAULT '0', user_approved_mdm tinyint(1) NOT NULL DEFAULT '0', remote_desktop_enabled tinyint(1) NOT NULL DEFAULT '0', activation_lock_enabled tinyint(1) NOT NULL DEFAULT '0', is_supervised tinyint(1) NOT NULL DEFAULT '0', is_activation_lock_manageable tinyint(1) NOT NULL DEFAULT '0', secure_boot_level varchar(20) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', external_boot_level varchar(20) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', jmf_settings_version int(11) NOT NULL DEFAULT '0', supports_ios_app_installs tinyint(1) NOT NULL DEFAULT '0', is_recovery_lock_enabled tinyint(1) NOT NULL DEFAULT '0', is_apple_silicon tinyint(1) NOT NULL DEFAULT '0', software_update_device_id varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', firewall_enabled tinyint(1) NOT NULL DEFAULT '0', PRIMARY KEY (computer_id), KEY computer_id (computer_id), KEY computer_name (computer_name), KEY udid (udid), KEY management_id (management_id), KEY last_report_id (last_report_id), KEY asset_tag (asset_tag), KEY bar_code_1 (bar_code_1), KEY bar_code_2 (bar_code_2), KEY last_location_id (last_location_id), KEY username (username), KEY realname (realname), KEY email (email), KEY department_name (department_name), KEY building_name (building_name), KEY room (room), KEY position (position), KEY mac_address (mac_address), KEY alt_mac_address (alt_mac_address), KEY serial_number (serial_number), KEY cd_last_report_id_is_managed_computer_id (last_report_id,is_managed,computer_id)) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;" 2>&1)
		debugging "table: computers_denormalized ${createComputersDenormalizedTable}" && checkMysqlErrors
		
		createMobileDevicesDenormalized=$($MYSQL --execute="CREATE TABLE IF NOT EXISTS mobile_devices_denormalized ( mobile_device_id int(11) NOT NULL DEFAULT '-1', display_name varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', asset_tag varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', udid varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', management_id varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', last_report_id int(11) NOT NULL DEFAULT '-1', last_report_date_epoch bigint(32) NOT NULL DEFAULT '0', last_backup_time_epoch bigint(32) NOT NULL DEFAULT '0', last_enrolled_date_epoch bigint(32) NOT NULL DEFAULT '0', is_managed tinyint(1) NOT NULL DEFAULT '0', wifi_mac_address varchar(20) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', bluetooth_mac_address varchar(20) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', serial_number varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', ip_address varchar(40) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', disk_size_mb int(11) NOT NULL DEFAULT '0', disk_available_mb int(11) NOT NULL DEFAULT '0', disk_percent_full int(11) NOT NULL DEFAULT '0', phone_number varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', model varchar(60) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', model_identifier varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', model_version_number varchar(20) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', os_version varchar(30) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', os_version_comparable int(11) NOT NULL DEFAULT '0', os_build varchar(30) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', modem_firmware varchar(30) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', last_location_id int(11) NOT NULL DEFAULT '-1', username varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '' COMMENT '[PII]', realname varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '' COMMENT '[PII]', email varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '' COMMENT '[PII]', department_id int(11) NOT NULL DEFAULT '-1' COMMENT '[PII]', building_id int(11) NOT NULL DEFAULT '-1' COMMENT '[PII]', department_name varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '' COMMENT '[PII]', building_name varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '' COMMENT '[PII]', room varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '' COMMENT '[PII]', phone varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '' COMMENT '[PII]', position varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '' COMMENT '[PII]', po_number varchar(60) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', vendor varchar(60) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', applecare_id varchar(60) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', leased tinyint(1) NOT NULL DEFAULT '0', purchased tinyint(1) NOT NULL DEFAULT '0', lease_date_epoch bigint(32) NOT NULL DEFAULT '0', po_date_epoch bigint(32) NOT NULL DEFAULT '0', warranty_date_epoch bigint(32) NOT NULL DEFAULT '0', purchase_price varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', life_expectancy int(11) NOT NULL DEFAULT '0', purchasing_account varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', purchasing_contact varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', hardware_encryption_capabilities tinyint(1) NOT NULL DEFAULT '-1', passcode_present tinyint(1) NOT NULL DEFAULT '0', block_level_encryption tinyint(1) NOT NULL DEFAULT '0', file_level_encryption tinyint(1) NOT NULL DEFAULT '0', data_protection tinyint(1) NOT NULL DEFAULT '0', passcode_is_compliant tinyint(1) NOT NULL DEFAULT '0', passcode_is_compliant_with_profile tinyint(1) NOT NULL DEFAULT '0', passcode_lock_grace_period_enforced bigint(32) DEFAULT NULL, iccid varchar(31) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', imei varchar(31) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', meid varchar(40) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', cellular_technology tinyint(1) NOT NULL DEFAULT '-1', voice_roaming_enabled tinyint(1) NOT NULL DEFAULT '-1', network varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', carrier varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', carrier_settings_version varchar(20) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', current_mobile_country_code varchar(20) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', current_mobile_network_code varchar(20) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', home_mobile_country_code varchar(20) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', home_mobile_network_code varchar(20) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', data_roaming_enabled tinyint(1) NOT NULL DEFAULT '0', is_roaming tinyint(1) NOT NULL DEFAULT '0', is_personal_hotspot_enabled tinyint(1) NOT NULL DEFAULT '0', battery_level int(11) NOT NULL DEFAULT '-1', is_supervised tinyint(1) NOT NULL DEFAULT '0', exchange_active_sync_device_id varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', enrollment_type int(11) NOT NULL DEFAULT '0', is_byo_profile_current tinyint(1) NOT NULL DEFAULT '0', tv_password varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', locales varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', languages varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', device_id varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', device_locator_service_enabled tinyint(1) NOT NULL DEFAULT '0', do_not_disturb_in_effect tinyint(1) NOT NULL DEFAULT '0', activation_lock_enabled tinyint(1) NOT NULL DEFAULT '0', cloud_backup_enabled tinyint(1) NOT NULL DEFAULT '0', last_cloud_backup_date_epoch bigint(32) NOT NULL DEFAULT '0', mdm_profile_removable tinyint(1) NOT NULL DEFAULT '0', system_integrity_state tinyint(1) NOT NULL DEFAULT '-1', ble_capable tinyint(1) NOT NULL DEFAULT '0', location_services_enabled tinyint(1) NOT NULL DEFAULT '0', device_name_type tinyint(1) NOT NULL DEFAULT '0', managed_device_name varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', itunes_store_account_is_active tinyint(1) NOT NULL DEFAULT '0', itunes_store_account_hash varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', device_certificate_expiration bigint(32) NOT NULL DEFAULT '-1', lost_mode tinyint(1) NOT NULL DEFAULT '0', lost_mode_enabled_date_epoch bigint(32) NOT NULL DEFAULT '0', is_device_multiuser tinyint(1) NOT NULL DEFAULT '0', diagnostic_submission_enabled tinyint(1) NOT NULL DEFAULT '0', app_analytics_enabled tinyint(1) NOT NULL DEFAULT '0', device_type tinyint(1) NOT NULL DEFAULT '-1', is_network_tethered tinyint(1) NOT NULL DEFAULT '0', resident_users bigint(32) DEFAULT NULL, quota_size bigint(32) DEFAULT NULL, time_zone varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', imei2 varchar(31) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', eid varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', KEY mobile_device_id (mobile_device_id), KEY display_name (display_name), KEY udid (udid), KEY management_id (management_id), KEY last_report_id (last_report_id), KEY wifi_mac_address (wifi_mac_address), KEY bluetooth_mac_address (bluetooth_mac_address), KEY serial_number (serial_number), KEY last_location_id (last_location_id), KEY username (username), KEY realname (realname), KEY email (email), KEY department_name (department_name), KEY building_name (building_name), KEY room (room), KEY position (position) ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;" 2>&1)
		debugging "table: mobile_devices_denormalized ${createMobileDevicesDenormalized}" && checkMysqlErrors
		
		createMobileDeviceExtensionAttributesTable=$($MYSQL --execute="CREATE TABLE IF NOT EXISTS mobile_device_extension_attributes (mobile_device_extension_attribute_id int(11) NOT NULL AUTO_INCREMENT, display_name varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', description longtext COLLATE utf8_unicode_ci, data_type tinyint(1) NOT NULL DEFAULT '0', type tinyint(1) NOT NULL DEFAULT '0', display_in_section varchar(20) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', checked tinyint(1) NOT NULL DEFAULT '0', ldap_attribute_mapping varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', ldap_extension_attribute_allowed tinyint(1) NOT NULL DEFAULT '0', PRIMARY KEY (mobile_device_extension_attribute_id), KEY mdea_display_name_extenstion_attribute_id (display_name,mobile_device_extension_attribute_id)) ENGINE=InnoDB AUTO_INCREMENT=10 DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;" 2>&1)
		debugging "table: mobile_device_extension_attributes ${createMobileDeviceExtensionAttributesTable}" && checkMysqlErrors
		
		createComputerExtensionAttributesTable=$($MYSQL --execute="CREATE TABLE IF NOT EXISTS extension_attributes (extension_attribute_id int(11) NOT NULL AUTO_INCREMENT, display_name varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', description longtext COLLATE utf8_unicode_ci, data_type tinyint(1) NOT NULL DEFAULT '0', type tinyint(1) NOT NULL DEFAULT '0', prompt_in_section varchar(20) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', display_in_section varchar(20) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', platform varchar(10) COLLATE utf8_unicode_ci NOT NULL DEFAULT 'osx', script_contents_mac longtext COLLATE utf8_unicode_ci, script_contents_windows longtext COLLATE utf8_unicode_ci, script_type_windows varchar(20) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', checked tinyint(1) NOT NULL DEFAULT '0', ldap_attribute_mapping varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', patch_extension_attribute_name varchar(255) COLLATE utf8_unicode_ci NOT NULL DEFAULT '', ldap_extension_attribute_allowed tinyint(1) NOT NULL DEFAULT '0', enabled tinyint(1) NOT NULL DEFAULT '1', PRIMARY KEY (extension_attribute_id), KEY display_name (display_name)) ENGINE=InnoDB AUTO_INCREMENT=60 DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;" 2>&1)
		debugging "table: extension_attributes ${createComputerExtensionAttributesTable}" && checkMysqlErrors
	fi
}

function checkMysqlTablesExist() {
	# confirm that the mysql talbes were created successfully or have not been removed
	tables=$($MYSQL --execute=" SHOW TABLES;" 2>&1)
	tablesReference=("computers_denormalized" "extension_attribute_values" "mobile_device_extension_attribute_values" "extension_attributes" "mobile_device_extension_attributes" "mobile_devices_denormalized" "reports")
	debugging "INFO: using database [$jamfDBname]"

	for reference in ${tablesReference[@]}
	do
		tableFound=false
		for table in ${tables[@]}
		do
			if [[ "$reference" == "$table" ]]
			then
				tableFound=true
				debugging "INFO: confirming mysql table exists: ${reference}"
			fi
		done
		if [[ "$tableFound" == false ]]
		then
			echo "ERROR: script cannot proceed - MySQL table not found: $reference...." >> $logFilePath
			echo "UPDATE: attempting to create table [$reference] for next time script runs...." >> $logFilePath
			# setting $lastSyncFile to "" to allow for databases table recreation
			lastSyncFile=""
			firstRunCreateDbTables
			exit 1
		fi
	done
}
					
function xmllintCheck() {
	if [[ "$ubuntuCheck" != "" ]]
	then
		# check for XMLLINT
		xmllintExists=$(which xmllint)
		if [[ "$xmllintExists" == "" ]]
		then
			echo "ERROR: XMLLINT not found.  Please run "sudo apt install libxml2-utils" to install...." >> $logFilePath
			echo "exited with error.  Check logs at ${logFilePath}...."
			exit 1
		fi	
	fi
}
				
function jqCheck() {
	jq=$(which jq)
	if [[ "$jq" == "" ]]
	then
		if [[ "$ubuntuCheck" == "" ]]
		then
			if [[ "$arch" == "arm64" ]]
			then
				jq=/opt/homebrew/opt/jq/bin/jq
			else
				jq=/usr/local/bin/jq
			fi
		else
			jq=/usr/bin/jq
		fi
	fi
	
	if [[ ! -e $jq ]]
	then
		echo "ERROR: jq not found.  Please run "sudo apt-get install jq" to install...." >> $logFilePath
		echo "exited with error.  Check logs at ${logFilePath}...."
		exit 1
	fi
}
					
function checkEnabledModes() {
	# if testMode is enabled, sets lastSyncEpoch and lastSyncFile to "" so that the script doesn't check last sync status for all computers / devices
	# and simply cycles through first computer and device
	if [[ "$testMode_TF" == true ]]
	then
		lastSyncEpoch=""
		lastSyncFile=""
		echo "-------------------" >> "$logFilePath"
		echo "TEST MODE ENABLED: ignoring last sync time and syncing only first record for each enabled device type...." >> "$logFilePath"
		echo "TEST MODE ENABLED: deleteBehavior=$deleteBehavior will be carried out on all records...." >> "$logFilePath"
		echo "-------------------" >> "$logFilePath"
	fi
	
	# writes to log file that debugMode is enabled and describes where to find the extra logging .txt files
	if [[ "$debugMode_TF" == true ]]
	then
		echo "-------------------" >> "$logFilePath"
		echo "DEBUG MODE ENABLED: detailed log entries will appear in this file.... " >> "$logFilePath"
		if [[ "$debugModeLogAllSyncedDataToTxtFiles_TF" == true ]]
		then
			echo "DEBUG MODE ENABLED[LOG ALL SYNCED DATA]: writing additional logs in $logFileDir [computers-${now}.txt and mobileDevices-${now}.txt]. Note these are overwritten on each run...." >> "$logFilePath"
		fi
		echo "-------------------" >> "$logFilePath"
	fi
	
	# writes to log file efficiencyMode status
	# if use
	if [[ "$useJPApiForFullIds_TF" == true ]] && [[ "$efficiencyMode" == "search" || "$efficiencyMode" == "filter"  ]]
	then
		echo "-------------------" >> "$logFilePath"
		echo "EFFICIENCY MODE NOT ENABLED[$efficiencyMode]: useJPApiForFullIds_TF is set to true. Set to false to use efficiency modes.... " >> "$logFilePath"
		echo "-------------------" >> "$logFilePath"
		efficiencyMode="" # set efficiencyMode to "" so that we can use only JPAPI paginated results
	fi
	# if efficiency mode is enabled and there is a last sync file
	if [[ "$efficiencyMode" == "search" || "$efficiencyMode" == "filter"  ]] && [[ -f "$lastSyncFile" ]]
	then
		echo "-------------------" >> "$logFilePath"
		echo "EFFICIENCY MODE ENABLED[$efficiencyMode]: script will create temporary Jamf Advanced searches or filters to find only devices with new data.... " >> "$logFilePath"
		if [[ "$deleteBehavior" != "" ]]
		then
			echo "DELETE BEHAVIOR NOT ENABLED[$deleteBehavior]: cannot perform delete behaviors while Efficiency Mode is enabled...." >> "$logFilePath"
		fi
		echo "-------------------" >> "$logFilePath"
	# if efficiency mode is enabled and there is no last sync file and test mode is disabled
	elif [[ "$efficiencyMode" == "search" || "$efficiencyMode" == "filter"  ]] && ! [[ -f "$lastSyncFile" ]] && [[ "$testMode_TF" == false ]]
	then
		echo "-------------------" >> "$logFilePath"
		echo "EFFICIENCY MODE NOT ENABLED[$efficiencyMode]: Efficiency Mode cannot be enabled until you have successfully synced Jamfcloud at least once...." >> "$logFilePath"
		echo "-------------------" >> "$logFilePath"
	# if efficiency mode is enabled and test mode is enabled
	elif [[ "$efficiencyMode" == "search" || "$efficiencyMode" == "filter"  ]] && [[ "$testMode_TF" == true ]]
	then
		echo "-------------------" >> "$logFilePath"
		echo "EFFICIENCY MODE NOT ENABLED[$efficiencyMode]: note that Efficiency Mode and Test Mode cannot be enabled simultaneously...." >> "$logFilePath"
		echo "-------------------" >> "$logFilePath"	
	fi
	
	# Set Eficiency Mode to normal if any other options need to set $lastSyncFile to nil or if it doesn't exist
	if [[ "$lastSyncFile" == "" ]] || ! [[ -f "$lastSyncFile" ]]
	then
		efficiencyMode=""
	fi
	# Ensure that auth type is correct is using Jamf Pro API
	if [[ "$efficiencyMode" == "filter" ]]
	then
		authTypeUseBearer_TF=true 
	fi
	
}
				
function deleteLogFiles() {
	# This function deletes log files older than the variable set in $deleteLogsOlderThan	
	find "$logFileDir" -mindepth 1 -mtime +$deleteLogsOlderThan -delete
}
					
function createLogDirAndFile() {
	# Create log directory if it doesn't exist
	if ! [[ -d "$logFileDir" ]]
	then
		mkdir "$logFileDir"
	fi
		# Create the log file
		if [[ -z $logFilePath ]]
		then
			touch "$logFilePath"
		fi
	
			# Clear the extra logging files on each run
			allLogFiles=$(ls "$logFileDir")
			if [[ "$allLogFiles" =~ .*"computers-20".* ]] || [[ "$allLogFiles" =~ .*"mobileDevices-20".* ]]
			then
				echo "INFO: deleting any old computer / device debug .txt files. To save these, please move to another directory...." >> $logFilePath
				rm -rf $logFileDir/computers-20* && rm -rf $logFileDir/mobileDevices-20*
			fi
	
	echo "View logs at ${logFilePath}...."
}
					
function printReport() {
echo "--------------------
------ REPORT ------
--------------------
Computer records created: $computersCreated
Computer records updated: $computersUpdated
Computer records deleted: $computersDeleted
Computer records set to unmanaged: $computersUnmanaged
Mobile device records created: $devicesCreated
Mobile device records updated: $devicesUpdated
Mobile device records deleted: $devicesDeleted
Mobile device records set to unmanaged: $devicesUnmanaged

Previous total computer records found in database: $totalCurrentComputersInMysql
Previous total device records found in database: $totalCurrentDevicesInMysql

New total computer records found in database: $totalNewComputersInMysql [unmanaged: $totalComputersUnmanaged]
New total device records found in database: $totalNewDevicesInMysql [unmanaged: $totalDevicesUnmanaged]
--------------------
------- END --------
--------------------" >> $logFilePath
}

function extensionAttributeOptionLogs() {
	##### Logs only if option to exclude computer or mobile device extension attributes is selected
	if [[ "$syncComputerExtensionAttributes_TF" != true ]] || [[ "$syncMobileDeviceExtensionAttributes_TF" != true ]]
	then
		echo "--------------------" >> $logFilePath
		echo "INFO: Extension Attribute records set to NOT sync for all device types...." >> $logFilePath
		echo "INFO: EA sync for computers: $syncComputerExtensionAttributes_TF" >> $logFilePath
		echo "INFO: EA sync for mobile devices: $syncMobileDeviceExtensionAttributes_TF" >> $logFilePath
		echo "--------------------" >> $logFilePath
	fi
	#####
}

################
##### Main #####
################
cleanUp # remove any old temp files before starting
echo "START: Script starting [v$scriptVersion]...." >> $logFilePath
setApiAuthenticationType
xmllintCheck
jqCheck
createLogDirAndFile
scriptDuration "start" 
firstRunCreateDbTables
checkMysqlTablesExist
checkEnabledModes
summarizeTables "previous"
echo "SYNC: Beginning data pull from $jss...." >> $logFilePath
extensionAttributeOptionLogs

if [[ "$syncComputers_TF" == true ]]
then
	refreshComputerEAnames=true
	tmpComputersAll=$(getAllIds "computers")
	parseAndUploadComputerInfo 
else
	echo "INFO: computer records set to NOT sync...." >> $logFilePath
fi
if [[ "$syncMobileDevices_TF" == true ]]
then
	refreshMobileDeviceEAnames=true 
	tmpDevicesAll=$(getAllIds "mobiledevices")
	parseAndUploadMobileDeviceInfo 
else
	echo "INFO: mobile device records set to NOT sync...." >> $logFilePath
fi
# Write epoch timestamp in receipt file
setLastSync 
cleanUp 
summarizeTables "new"
printReport 
scriptDuration "stop"
deleteLogFiles
					
