#!/bin/bash
#
#	This script allows install IPA via command line
#	Author: autopear
#	You may NOT modify any of these codes without my permission.
#	All rights resvered.
#
#	This script is low and may contain errors, please use the executable version instead.
#
if [[ ! -f /usr/bin/unzip ]]; then
	echo "Please install unzip from Cydia."
	exit 1
fi
if [[ ! -f /usr/bin/plutil ]]; then
	echo "Please install Erica Utilities from Cydia."
	exit 1
fi
if [[ ! -f /usr/bin/basename ]]; then
	echo "Please install Core Utilities from Cydia."
	exit 1
fi
if [[ ! -f /usr/bin/dirname ]]; then
	echo "Please install Core Utilities (/bin) from Cydia."
	exit 1
fi
if [[ ! -f /bin/grep ]]; then
	echo "Please install grep from Cydia."
	exit 1
fi
if [[ ! -f /bin/sed ]]; then
	echo "Please install sed from Cydia."
	exit 1
fi
if [[ ! -f /usr/bin/find ]]; then
	echo "Please install Find Utilities from Cydia."
	exit 1
fi
if [[ ! -f /usr/bin/dpkg ]]; then
	echo "Please install Debian Packager from Cydia."
	exit 1
fi
if [[ ! -f /usr/bin/sw_vers ]]; then
	echo "Please install Darwin Tools from Cydia."
	exit 1
else
	sysVersion=$(sw_vers -productVersion)
fi
if [[ ! -f /usr/bin/uicache ]]; then
	echo "Please install UIKit Tools from Cydia."
	exit 1
fi
if [[ ! -f /usr/bin/fixblankicon ]]; then
	echo "Cannot find /usr/bin/fixblankicon, please reinstall this package via trusted source."
	exit 1
fi

forceInstall="NO"
metaData="YES"
keepFile="YES"
quietMode="NO"
successToggle="NO"

if [ $# -le 0 ]; then
	echo -e "Usage: $(basename "$0") [OPTION]... [FILE]...\nInstall applications in IPA format via command line.\n\nOptions:\n    -a  Show about information.\n    -d  Delete IPA file(s) after installation.\n    -f  Force installation, do not check compatibilities.\n    -h  Display usage information.\n    -q  Quiet mode, suppress all outputs.\n    -r  Remove Metadata.plist."
	exit 0
else
	while getopts ahfqrd OPTION; do
		case $OPTION in
			a) echo -e "About $(basename "$0")\nInstall IPA via command line.\nVersion: 1.1\nAuhor: autopear";exit 0;;
			h) echo -e "Usage: $(basename "$0") [OPTION]... [FILE]...\nInstall applications in IPA format via command line.\n\nOptions:\n    -a  Show about information.\n    -d  Delete IPA file(s) after installation.\n    -f    Force installation, do not check compatibilities.\n    -h  Display usage information.\n    -q  Quiet mode, suppress all outputs.\n    -r  Remove Metadata.plist.";exit 0;;
			f) forceInstall="YES";;
			q) quietMode="YES";;
			r) metaData="NO";;
			d) keepFile="NO";;
			\?) echo "Invalid option: $OPTION";exit 1;;
		esac
	done
fi
if [ $OPTIND -gt $# ]; then
	echo "Please specify IPA filename(s)."
	exit 1
fi

hasTDMTANF="NO"
if [ -e /var/mobile/tdmtanf ]; then
	hasTDMTANF="YES"
	mv -f /var/mobile/tdmtanf /var/mobile/disabled-tdmtanf
fi

while [ $# -ge 1 ]; do
	if [[ "$1" != -* ]]; then
		if [[ "$1" == *.[Ii][Pp][Aa] ]]; then
			#use script method to install, low efficiency but works for many system versions
			if [ $quietMode == "NO" ]; then
				echo
				echo "Processing \"$1\"..."
			fi
			unzip_dir=$(date +%s%N | md5sum | cut -b -32)
			if [[ $(whoami) == "root" ]]; then
				unzip_dir="/tmp/"$unzip_dir
			else
				unzip_dir="/private/var/mobile/tmp/"$unzip_dir
			fi
			if [ -e "$unzip_dir" ]; then
				rm -fr "$unzip_dir"
			fi
			mkdir -p "$unzip_dir"
			unzip -qqKX "$1" -d "$unzip_dir" 1>/dev/null 2>&1

			find "$unzip_dir" -name ".DS_Store" -exec rm -f {} \; 1>/dev/null 2>&1
			find "$unzip_dir" -name "._*" -exec rm -rf {} \; 1>/dev/null 2>&1

			bundleName=$(basename "$unzip_dir"/Payload/*.app)

			if [ -f "$unzip_dir"/Payload/"$bundleName"/Info.plist ]; then
				breakToggle="NO"
				if [ $quietMode == "NO" ]; then
					echo -e "    Reading IPA information..."
				fi
				InfoPlist="$unzip_dir/Payload/$bundleName/Info.plist"
				app_id=$(plutil -CFBundleIdentifier "$InfoPlist" 2>&1)
				app_ver=$(plutil -CFBundleVersion "$InfoPlist" 2>&1)
				app_exec=$(plutil -CFBundleExecutable "$InfoPlist" 2>&1)
				min_os=$(plutil -MinimumOSVersion "$InfoPlist" 2>&1)
				capabilities=$(plutil -UIRequiredDeviceCapabilities "$InfoPlist" 2>&1 | sed 's/,/\n/g' |  sed 's/["(){}; ]//g' | grep -v "^$")
				
				cp -f "$InfoPlist" "$unzip_dir"/Info.plist
				if [ $forceInstall == "NO" ]; then
					if [ $quietMode == "NO" ]; then
						echo -e "    Checking capabilities..."
					fi
					if [[ $(uname -m) == iPhone* || $(uname -m) == iPod* ]]; then
						device="1"
					fi
					if [[ $(uname -m) == iPad* ]]; then
						device="2"
					fi
					if [[ $(uname -m) == AppleTV* ]]; then
						device="3"
					fi
					if [[ $(plutil -UIDeviceFamily "$InfoPlist" 2>&1 | grep "1") == "" ]]; then
						if [[ $(plutil -UIDeviceFamily "$InfoPlist" 2>&1 | grep $device) == "" ]]; then
							echo -e "    This application does not support your device."
							if [ $quietMode == "NO" ]; then
								echo -e "    Cleaning..."
							fi
							rm -fr "$unzip_dir"
							if [ -e /private/var/mobile/tmp/ ]; then
								rmdir --ignore-fail-on-non-empty /private/var/mobile/tmp/
							fi
							breakToggle="YES"
						fi
					fi

					if [[ "$sysVersion" < "$min_os" ]]; then
						echo -e "    This application requires iOS firmware higher than $min_os."
						if [ $quietMode == "NO" ]; then
							echo -e "    Cleaning..."
						fi
						rm -fr "$unzip_dir"
						if [ -e /private/var/mobile/tmp/ ]; then
							rmdir --ignore-fail-on-non-empty /private/var/mobile/tmp/
						fi
						breakToggle="YES"
					fi
					
					if [[ $(echo $capabilities | grep "Objectnotfound") == "" && "$capabilities" != "" ]]; then
						num=$(echo $capabilities | sed 's/ /\n/g' | wc -l)
						cnt=1
						for foo in $(echo $capabilities | sed 's/ /\n/g'); do
							if [[ $(echo $foo | grep "=0") != "" ]]; then
								if [[ $(dpkg -s "gsc."$(echo $foo | cut -f1 -d'=') 2>&1 | grep -F "Status: install ok installed") != "" ]]; then
									echo -e "    This application conflicts with capability \"$(echo $foo | cut -f1 -d'=')\"."
									if [ $quietMode == "NO" ]; then
										echo -e "    Cleaning..."
									fi
									rm -fr "$unzip_dir"
									if [ -e /private/var/mobile/tmp/ ]; then
										rmdir --ignore-fail-on-non-empty /private/var/mobile/tmp/
									fi
									breakToggle="YES"
								fi				
							else
								if [[ $(dpkg -s "gsc."$(echo $foo | cut -f1 -d'=') 2>&1 | grep -F "Status: install ok installed") == "" ]]; then
									echo -e "    This application requires capability \"$(echo $foo | cut -f1 -d'=')\"."
									if [ $quietMode == "NO" ]; then
										echo -e "    Cleaning..."
									fi
									rm -fr "$unzip_dir"
									if [ -e /private/var/mobile/tmp/ ]; then
										rmdir --ignore-fail-on-non-empty /private/var/mobile/tmp/
									fi
									breakToggle="YES"
								fi
							fi
						done			
					fi
				fi

				if [ $breakToggle == "NO" ]; then
					if [ $quietMode == "NO" ]; then
						echo -e "    Installing..."
					fi

					if [[ $(plutil -CFBundleIdentifier /private/var/mobile/Applications/*/*.app/Info.plist 2>&1 | grep "^$app_id$") == "" ]]; then
						#Generate app directory
						while [ 1 -lt 2 ]; do
							install_path=$(date | md5sum | tr '[:lower:]' '[:upper:]' | cut -b-8)
							install_path+="-"$(date +%s%N | md5sum | tr '[:lower:]' '[:upper:]' | cut -b-4)
							install_path+="-"$(date +%s%N | md5sum | tr '[:lower:]' '[:upper:]' | cut -b-4)
							install_path+="-"$(date +%s%N | md5sum | tr '[:lower:]' '[:upper:]' | cut -b-4)
							install_path+="-"$(date +%s%N | md5sum | tr '[:lower:]' '[:upper:]' | cut -b-12)
							if [[ ! -e /private/var/mobile/Applications/$install_path ]]; then
								break
							fi
						done
						#Create required directories and files
						mkdir -p /private/var/mobile/Applications/$install_path
						mkdir -p /private/var/mobile/Applications/$install_path/Documents
						mkdir -p /private/var/mobile/Applications/$install_path/Library/Caches
						mkdir -p /private/var/mobile/Applications/$install_path/Library/Preferences
						mkdir -p /private/var/mobile/Applications/$install_path/tmp
						if [[ ! -f /private/var/mobile/Library/Preferences/com.apple.PeoplePicker.plist ]]; then
							plutil -create /private/var/mobile/Library/Preferences/com.apple.PeoplePicker.plist >/dev/null
							plutil -key memberListOffset -real 0.0 /private/var/mobile/Library/Preferences/com.apple.PeoplePicker.plist >/dev/null
							chown 501:501 /private/var/mobile/Library/Preferences/com.apple.PeoplePicker.plist
						fi
						ln -s /private/var/mobile/Library/Preferences/com.apple.PeoplePicker.plist /private/var/mobile/Applications/$install_path/Library/Preferences/com.apple.PeoplePicker.plist
						ln -s /private/var/mobile/Library/Preferences/.GlobalPreferences.plist /private/var/mobile/Applications/$install_path/Library/Preferences/.GlobalPreferences.plist
					else
						#Update existing path
						install_path=$(plutil -User -"$app_id" -Container /var/mobile/Library/Caches/com.apple.mobile.installation.plist 2>&1)
						install_path=$(echo $install_path | sed 's/private\/var\/mobile\/Applications//g' | sed 's/\///g')
						rm -fr /private/var/mobile/Applications/$install_path/*.app
					fi
				
					#Move files
					mv -f "$unzip_dir"/Payload/"$bundleName" /private/var/mobile/Applications/$install_path
					if [[ -f "$unzip_dir"/iTunesArtwork ]]; then
						mv -f "$unzip_dir"/iTunesArtwork /private/var/mobile/Applications/$install_path/
					fi
					if [[ -f "$unzip_dir"/iTunesMetadata.plist && $metaData == "YES" ]]; then
						mv -f "$unzip_dir"/iTunesMetadata.plist /private/var/mobile/Applications/$install_path/
					fi
					#Recover backup
					if [ -e "$unzip_dir"/Container/ ]; then
						rm -f "$unzip_dir"/Container/Library/Preferences/.GlobalPreferences.plist "$unzip_dir"/Container/Library/Preferences/com.apple.*.plist
						cp -af "$unzip_dir"/Container/* /private/var/mobile/Applications/$install_path/
					fi
					#Set up permissions
					chown -R mobile:mobile /private/var/mobile/Applications/$install_path
					chmod 0755 /private/var/mobile/Applications/$install_path/"$bundleName"/"$app_exec"
					#Insert Mobile Installation records
					plutil -key ApplicationType -string User "$unzip_dir"/Info.plist >/dev/null
					plutil -key Container -string "/private/var/mobile/Applications/$install_path" "$unzip_dir"/Info.plist >/dev/null
					plutil -key Path -string "/private/var/mobile/Applications/$install_path/$bundleName" "$unzip_dir"/Info.plist >/dev/null
					if [ -e "/private/var/mobile/Applications/$install_path/$bundleName/Settings.bundle/" ]; then
						plutil -key HasSettingsBundle -1 "$unzip_dir"/Info.plist >/dev/null
					fi
					if [[ ! -e /System/Library/Frameworks/NewsstandKit.framework/ ]]; then
						plutil -key SandboxProfile -string "/private/var/mobile/Applications/$install_path".sb "$unzip_dir"/Info.plist >/dev/null
					fi
					plutil -key EnvironmentVariables -dict "$unzip_dir"/Info.plist >/dev/null
					plutil -key EnvironmentVariables -type json -value '{"CFFIXED_USER_HOME":"/private/var/mobile/Applications/STR_INSTALL_PATH", "TMPDIR":"/private/var/mobile/Applications/STR_INSTALL_PATH/tmp", "HOME":"/private/var/mobile/Applications/STR_INSTALL_PATH"}' "$unzip_dir"/Info.plist >/dev/null
					plutil -xml "$unzip_dir"/Info.plist >/dev/null
					sed -i "s/STR_INSTALL_PATH/$install_path/g" "$unzip_dir"/Info.plist
					cp -f /private/var/mobile/Library/Caches/com.apple.mobile.installation.plist "$unzip_dir"/temp.plist >/dev/null
					checkUser=$(plutil -User "$unzip_dir"/temp.plist >/dev/null 2>&1)
					if [[ $(echo $checkUser | grep "Object not found") != "" ]]; then
						plutil -User -dict "$unzip_dir"/temp.plist >/dev/null
					fi
					plutil -User -key $app_id -string "This-is-to-be-replaced" "$unzip_dir"/temp.plist >/dev/null
					plutil -xml "$unzip_dir"/temp.plist >/dev/null
					if [[ -e /private/var/mobile/Applications/$install_path/"$bundleName"/SC_Info/ ]]; then
						numDSID=$(($(grep -nm 1 "<key>ApplicationDSID</key>" "$unzip_dir"/temp.plist | cut -f1 -d':')+1))
						DSID=$(sed -n "$numDSID"p "$unzip_dir"/temp.plist | cut -f2 -d'>' | cut -f1 -d'<')
						plutil -key ApplicationDSID -string $DSID "$unzip_dir"/Info.plist >/dev/null
					fi
					infoContent=$(tail -n +4 "$unzip_dir"/Info.plist | grep -v "^</plist>$" | sed 's/\//\\\//g' | sed 's/\?/\\\?/g' | sed 's/\!/\\\!/g' | sed 's/\[/\\\[/g' | sed 's/\]/\\\]/g' | sed 's/\&/\\\&/g' | tr '[\n\t]' ' ')
					sed -i "s/<string>This-is-to-be-replaced<\/string>/$infoContent/g" "$unzip_dir"/temp.plist
					plutil -binary "$unzip_dir"/temp.plist >/dev/null
					mv -f "$unzip_dir"/temp.plist /private/var/mobile/Library/Caches/com.apple.mobile.installation.plist
					chown mobile:mobile /private/var/mobile/Library/Caches/com.apple.mobile.installation.plist
					#Clean temporary files
					if [ $quietMode == "NO" ]; then
						echo -e "    Cleaning..."
					fi
					rm -fr "$unzip_dir"
					if [ -e /private/var/mobile/tmp/ ]; then
						rmdir --ignore-fail-on-non-empty /private/var/mobile/tmp/
					fi
					#Remove ipa
					if [ $keepFile == "NO" ]; then
						if [ $quietMode == "NO" ]; then
							echo -e "    Deleting \"$1\"..."
						fi
						rm -f "$1"
					fi
					successToggle="YES"
				fi
			else
				echo -e "\tInvalid ipa!"
				if [ $quietMode == "NO" ]; then
					echo -e "\tCleaning..."
				fi
			fi
		else
			echo "\"$1\" is not an IPA file or does not exist."
		fi
	fi
	shift
done
if [ "$successToggle" == "YES" ]; then
	if [ $forceInstall == "YES" ]; then
		#Show icon
		if [ $quietMode == "NO" ]; then
			echo -e "\nRefreshing icons...\n    The SpringBoard may freeze for a short while."
		fi
		currentDir=$(pwd)
		cd /private/var/mobile/
		if [[ $(whoami) == "mobile" ]]; then
			uicache 1>/dev/null 2>&1
		else
			su mobile -c uicache 1>/dev/null 2>&1
		fi
		cd "$currentDir"
		/usr/bin/fixblankicon 1>/dev/null 2>&1
	fi
	if [ $quietMode == "NO" ]; then
		echo -e "Done."
	fi
fi
if [ $hasTDMTANF == "YES" ]; then
	if [ -e /var/mobile/disabled-tdmtanf ]; then
		mv /var/mobile/disabled-tdmtanf /var/mobile/tdmtanf
	fi
fi
exit 0
