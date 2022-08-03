# Sync Jamfcloud Data Script


## Preface
The purpose of this script is to sync specific data points from Jamfcloud to an on-premise MySQL database hosted on a Linux (Ubuntu) server.  The script is intended to automatically run on the server at a set interval but can also be run manually from a remote Mac.

### Datapoints Collected for Mac Computers:
Serial number, asset tag, operating system version, computer model, building, room, department, username, last IP, computer name, MAC address, computer ID, PO number, PO date epoch, warranty date epoch, managed status and extension attributes.

### Datapoints Collected for Mobile Devices:
Mobile device ID, model, serial number, display name, wifi MAC address, IP address, OS version, building, room, department, username, PO date epoch, PO number, warranty date epoch, model version number, managed status and extension attributes.

## Prerequisites
The following are prerequisites for Jamfcloud-to-database syncing.

### Jamfcloud Environment
- Jamf Pro URL (the Jamfcloud instance from which we are syncing data).
- Read-only API credentials for the script to access the Jamfcloud instance.
- Note, enabling **search** Efficiency Mode (see below) requires API user to have the ability to create, read and delete Advanced Computer and Mobile Device Searches.


### Linux Server Hosting Database
- A server running Ubuntu Linux (this script has been tested on Ubuntu 21.04 / Ubuntu Server 20.04).  This server must be able to see your Jamf Pro instance.
- MySQL Community Server
- jq and XMLLINT.

### If Running Script from a Remote Mac
MySQL client (only needed if NOT running this script on a server).

## Configure Ubuntu Server and MySQL

### Install MySQL Community Server
To install MySQL on your server, open Terminal and run the following commands:
```bash
sudo apt update 
```
```bash
sudo apt install mysql-server 
```
MySQL should now be installed. Next, run the following command to securely setup and create a root password for MySQL:
```bash
sudo mysql_secure_installation 
```
To access MySQL using the “root” account you just setup, run the following command:
 ```bash
 mysql -u root -p 
 ```
You should see the MySQL command prompt:
```bash
 mysql> 
 ```

## Create the Backup Database
Next, we’ll create the database we’re syncing Jamfcloud information to.  If not already logged into MySQL, run:
 ```bash
 mysql -u root -p 
 ```
Create the database using the following command.  In this case, the database being created is called “jamfcloudbackups” but can be named as desired.
```bash
mysql> CREATE database jamfcloudbackups; 
```
## Create the MySQL User
Next, a MySQL user must be created for the script to utilize.  As with previous examples, the following username can be unique from what is shown:
```bash
mysql> CREATE USER 'dbuser'@'localhost' IDENTIFIED BY 'dbUserPassword';
```
After the MySQL user is created, grant it access to the newly-created database:
```bash
 mysql> GRANT ALL ON jamfcloudbackups.* TO ‘dbuser’@‘localhost’; 
 ```
If running **on remote Mac ONLY**, ensure that the MySQL user can access the remote database from your IP address:
```bash
 mysql> GRANT ALL ON jamfcloudbackups.* TO ‘dbuser’@‘your.IP.address’; 
```
## Install MySQL Client
**This step is only necessary if NOT running the script on the same server as the MySQL database.**  For example, if you plan to run the script on a local Mac to initiate the backups to a remote Ubuntu server.

### macOS (via Homebrew):
Install Homebrew by going to the following link and following instructions: https://brew.sh/.
With Homebrew installed, run the following commands in Terminal to install MySQL Client:
```bash
brew install mysql-client 
```

## Additional MySQL Configuration
If running the script from a remote computer, you will likely need to complete additional items to allow for access to the database.

### Modify mysqld.cnf File to Allow for Remote Access to Database
 ```bash
 sudo nano /etc/mysql/mysql.conf.d/mysqld.cnf 
 ```
Add a “#” to the following line to comment it out:
Before
```bash
 bind-address  = 127.0.0.1 
```
After
```bash
 # bind-address  = 127.0.0.1 
 ```
Save the file.

### Modify Server Firewall Settings
If you are still unable to access the database remotely, ensure the firewall is allowing access:
 ```bash
 sudo ufw status 
 ```
 ```bash
 sudo ufw allow mysql 
 ```
 ```bash
 sudo service ufw restart 
 ```

## Create .ENV / .CNF Files
The script relies on two files that store environmental variables.  One stores information about the Jamfcloud instance, the API user used to access it and target MySQL host and database names.  The other stores the login information for the target database.  Note, we will be using the MySQL database name, MySQL user and MySQL user password created in the previous steps.
	

### Create the .ENV File
To create the first .env file, perform the following steps.
Open the Terminal app and type the following command:
 ```bash
nano ~/.sync_jamfcloud_data.env 
 ```
The file should be formatted as shown in the image below.  Please make sure to not change any of the variables in all-caps, while the placeholders after the “=“ sign must correctly reflect your environment:

 ```bash
JSSUSER=jamfUser
JSSPASS=jamfUserPw
JSS=https://myinstance.jamfcloud.com
JAMFDBNAME=databaseName
JAMFDBHOST=localhost
 ```

- JSSUSER
	- The username you are using for API access to your Jamfcloud instance.
- JSSPASS
	- The password for the above account.
- JSS
	- The full URL for your Jamfcloud instance.
- JAMFDBNAME
	- The name of the target MySQL database on your Linux server.
- JAMFDBHOST
	- The IP address or FQDN of the server hosting the MySQL database.  If running on Ubuntu server, use “localhost” rather than an IP address or FQDN.

When finished editing, press CTRL+X, then press Y, then return.

### Create the .CNF File
Open the Terminal app and type the following:
```bash
nano ~/.my.cnf 
 ```
 
Enter text as shown in the screenshot below.  Make sure that the values after the “=“ signs reflect your environment’s values.
 ```bash
[client]
user=mysqlUser
password=mysqlUserPw
 ```
- user
	- The MySQL user created previously in this document.
- password
	- The password for the above account.

When finished editing, press CTRL+X, then press Y, then return.
Additional step (optional security measure): change permissions on this file so that other users on the server cannot access this file.  To do this, run the following command:
```bash
chmod 600 ~/.my.cnf
```

## Install jq
The script requires this dependency to parse JSON and can be downloaded from Homebrew if using a Mac or by running the following command on Ubuntu:
```bash
sudo apt-get install jq
```

## Install XMLLINT (Ubuntu)
The script utilizes XMLLINT to parse XML data from Jamf Pro.  This is included in macOS but must be manually installed on Ubuntu.  
To install, run the following command:
```bash
sudo apt install libxml2-utils 
```
  
## Script Functionality
The script will perform as follows:
- When the script runs for the first time, it will copy all of the desired datapoints to the target database.  When it runs subsequent times, the script will check to see if the computer / mobile device information has been updated in Jamfcloud since the last successful script run and only make updates to the database for devices that have recently updated their inventory records in Jamf.  As a result, the first-run of the script may take some time to complete but later runs of the script will be much faster.
- If a computer or mobile device is deleted from Jamfcloud, the script will perform as indicated by how the ```$deleteBehavior``` variable is configured.  This is covered in the section below under Delete Behavior **(note that this option cannot be enabled simultaneously with an Efficiency Mode).**

## Setting Script Options
The script can be configured with several options.  For instance, you can choose to sync only computers, only mobile devices, both or choose to exclude or include extension attribute data.  You can configure how the script handles deleted Jamfcloud records or utilize Test or Debug Modes.

The following are a list of variables that can be customized within the script:

### Sync Mobile Devices
Include or exclude mobile devices in the sync (true or false):
 ```bash
 syncMobileDevices_TF 
  ```

### Sync Computers
Include or exclude computers in the sync (true or false):
 ```bash
 syncComputers_TF 
  ```

### Sync Extension Attributes
Include or exclude computer and mobile device extension attribute values in the sync (true or false):
```bash
syncComputerExtensionAttributes_TF 
 ```
 ```bash
 syncMobileDeviceExtensionAttributes_TF 
 ```

### Delete Behavior
Action to be taken when the script encounters a computer or device that has been deleted from the source Jamf Pro instance (**“delete”**, **“unmanage”**, or **“”**):
- **“delete"** = deletes the record from the MySQL backup database.
- **“unmanage"** = sets the record in the backup database to “unmanaged” but does not delete it.
- **“”** = does not do anything, although entries will display in the logs that record(s) were deleted from the source Jamf Pro instance.
Note that ```$deleteBehavior``` and ```$efficiencyMode``` cannot be enabled simultaneously.
 ```bash
deleteBehavior 
 ```

### Test Mode
Enabling Test Mode instructs the script to only sync the first computer and mobile device from the Jamf Pro instance, regardless of the last time those devices have synced (true or false):
 ```bash
testMode_TF 
 ```

### Debug Mode
Enabling Debug Mode creates additional logging in the primary log file and creates a printout of computer and mobile device sync data in two text files in the same directory (true or false):
 ```bash
 debugMode_TF 
 ```
 
### Debug Mode [Log All Synced Data To .TXT Files]
Further debugging can be enabled in the form of text files that display the contents of the synced data in two .txt files (one for computers and one for mobile devices) in the ~/JamfSync directory.  This can be helpful to confirm that data is syncing correctly but can consume a large amount of space.  Note that these files will be deleted each time the script runs (true or false):
 ```bash
 debugModeLogAllSyncedDataToTxtFiles_TF
  ```

### Efficiency Mode
As the name suggests, Efficiency Mode options are intended to provide for a more efficient  data pull from Jamf Pro. Efficiency Mode has three options (“”, “search”, “filter”):
- **“”** = leaving the variable blank runs the standard script and checks each computer / device record for new data.
- **“search”** = using the Jamf Classic API, the script creates temporary Advanced Computer / Mobile Device Searches to find devices that have updated Jamf Pro information since the last successful sync.
Note that using this option requires the API user account to have additional permissions to create and delete Advanced Computer Searches and Advanced Mobile Device Searches, in addition:
- **“filter”** = using the Jamf Pro API, the script filters results to only retrieve computers and devices that have updated data in Jamf since last successful sync, without creating additional Advanced Computer or Mobile Device Searches.
```bash
efficiencyMode 
```

### Use Jamf Pro APIs to Fetch All IDs
This option is another efficiency configration.  When set to **true && $efficiencyMode=""**, the script will utilize the newer Jamf Pro API and retrieve inventory from Jamf Pro using a paginated process that is more friendly on servers when dealing with large numbers of devices.
```bash
useJPApiForFullIds_TF=true
```

### Authentication Type
Enabling this option to true utilizes the Jamf API Bearer Token authentication method.  When set to false, the script uses Basic Authentication, which is deprecated and will be removed from in a future version of Jamf Pro.
```bash
authTypeUseBearer_TF=true 
```

### Delete Logs after Specified Days
To prevent the log file directory from becoming too cluttered, this option automatically deletes .log files after a specified period.  To configure, enter a value in days, as shown below.
```bash
deleteLogsOlderThan="14"
```


## Logs
When the script is run, logs will appear in the following directory:
```bash
 ~/JamfSync 
```

The primary log file will be named as follows (according to date and time) ```jamfProDbSync_20220114-103448.log```.

If Debug Mode is enabled, two additional files (```computers-date-time.txt``` and ```mobileDevices-date-time.txt```) will appear in the same directory and will output the values synced to the database.  This can be used to confirm that the database is updating correctly.  Note that these files will be overwritten each time the script is run in Debug Mode.

## Running the Script
You can run the script manually by dragging / dropping the script icon into the Terminal window (the path to the script will auto-complete) then ```press return```.
Alternatively, you can navigate to the directory where the script resides and run it as follows:
 ```bash
 ./Sync_Jamfcloud_Data.sh 
```

### Set Script to Run Automatically
The script is designed to be configured once and run automatically, at an interval that works for you.  To enable automatic syncing, open Terminal and run the following command:
```bash
crontab -e 
```

Select the editor you want to use by choosing a number.  In the editor that appears, enter the ```cron``` frequency then the script location.  In the following example, the script runs every 24 hours:
```bash
 */24 * * * /home/myUsername/Desktop/Scripts/Sync_Jamfcloud_Data.sh 
 ```

Save the file.
To view your setting, run the following command:
```bash
crontab -l 
```
