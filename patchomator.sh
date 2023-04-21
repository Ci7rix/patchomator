#!/bin/zsh

# Version: 2023.04.20.MOO
# (Major Overhaul Operation)

# Big Thanks to:
# 	Adam Codega
# 	@tlark
# 	@mickl089
# 	Shad Hass
# 	Derek McKenzie
# 	Armin Briegel

# To Do:
# Add MDM deployed Non-interactive Mode
# Install package

# Changed:
# Major overhaul based on MacAdmins #patchomator feedback
# 7 days -> 30 days
# Added required/excluded keys in preference file
# system-level config file for running via sudo, or deploying via MDM
# git and Xcode tools are optional now. Did you know GitHub has a pretty decent API?
# No longer requires root for normal operation. (thanks, @tlark)
# Downloads XCode Command Line Tools to provide git (Thanks Adam Codega)

# Done:
# use release version of installomator, not dev. (Thanks Adam Codega)
# selfupdate when labels are older than 7 days
# parse label name, expectedTeamID, packageID
# match to codesign -dvvv of *.app 
# packageID to Identifier
# expectedTeamID to TeamIdentifier
# added quiet mode, noninteractive mode
# choose between labels that install the same app (firefox, etc) 
# - offer user selection
# - pick the first match (noninteractive mode)
# on duplicate labels, skip subsequent verification
# on -I, parse generated config, pipe to Installomator to install updates
#   Installomator requires root

# NGD:
# self-update switch branches from release to latest source



if [ -z "${ZSH_VERSION}" ]; then
	>&2 echo "[ERROR] This script is only compatible with Z shell (/bin/zsh). Re-run with"
	echo "\t zsh patchomator.sh"
	exit 1
fi

# Environment checks

OSVERSION=$(defaults read /System/Library/CoreServices/SystemVersion ProductVersion | awk '{print $1}')
OSMAJOR=$(echo "${OSVERSION}" | cut -d . -f1)
OSMINOR=$(echo "${OSVERSION}" | cut -d . -f2)


if [[ $OSMAJOR -lt 11 ]] && [[ $OSMINOR -lt 13 ]]
then
	echo "[ERROR] Patchomator requires MacOS 10.13 or higher."
	exit 1
fi


# Check your privilege
if [ $(whoami) = "root" ]
then
	IAMROOT=true
else
	IAMROOT=false
fi


# log levels from Installomator/fragments/arguments.sh

if [[ $DEBUG -ne 0 ]]; then
    LOGGING=DEBUG
elif [[ -z $LOGGING ]]; then
    LOGGING=INFO
    datadogLoggingLevel=INFO
fi

declare -A levels=(DEBUG 0 INFO 1 WARN 2 ERROR 3 REQ 4)

declare -A configArray=()

# declare -A labelsArray=()


# default paths
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

InstallomatorPATH=("/usr/local/Installomator/Installomator.sh")
configfile=("/Library/Application Support/Patchomator/patchomator.plist")
patchomatorPath=$(dirname $0) # default install at /usr/local/Installomator/
fragmentsPATH=("$patchomatorPath/fragments")

# Pretty print
BOLD=$(tput bold)
RESET=$(tput sgr0)
RED=$(tput setaf 1)
YELLOW=$(tput setaf 3)



# # # # #
# functions

usage() {
	echo "\n${BOLD}Usage:${RESET}"
	echo "\tpatchomator.sh [ -ryqvIh  -c configfile  -p InstallomatorPATH ]\n"
	echo "${BOLD}Default:${RESET}"
	echo "\tScans the system for installed apps and matches them to Installomator labels. Creates a new config file or refreshes an existing one. \n"
	echo "\t${BOLD}-r | --read \t${RESET} Read Config. Parses and displays an existing config file. Default path ${YELLOW}/Library/Application Support/Patchomator/patchomator.plist${RESET}"
	echo "\t${BOLD}-c | --config \"path to config file\" \t${RESET} Overrides default configuration file location."
	echo "\t${BOLD}-y | --yes \t${RESET} Non-interactive mode. Accepts the default (usually nondestructive) choice at each prompt. Use with caution."
	echo "\t${BOLD}-q | --quiet \t${RESET} Quiet mode. Minimal output."
	echo "\t${BOLD}-v | --verbose \t${RESET} Verbose mode. Logs more information to stdout. Overrides ${BOLD}-q${RESET}"
	echo "\t${BOLD}-I | --install \t${RESET} Install mode. This parses an existing configuration and sends the commands to Installomator to update. ${BOLD}Requires sudo${RESET}"
	echo "\t${BOLD}-p | --pathtoinstallomator \"path to Installomator.sh\" \t${RESET} Default Installomator Path ${YELLOW}/usr/local/Installomator/Installomator.sh${RESET}"
	echo "\t${BOLD}-h | --help \t${RESET} Show this text and exit.\n"
	exit 0
}


makepath() {
	mkdir -p "$(sed 's/\(.*\)\/.*/\1/' <<< $1)" # && touch $1
}

notice() {
    if [[ ${#verbose} -eq 1 ]]; then
        echo "${YELLOW}[NOTICE]${RESET} $1"
    fi
}

infoOut() {
	if ! [[ ${#quietmode} -eq 1 ]]; then
		echo "$1"
	fi
}

error() {
	echo "${BOLD}[ERROR]${RESET} $1"
	let errorCount++
}

fatal() {
	echo "\n${BOLD}${RED}[FATAL ERROR]${RESET} $1\n\n"
	exit 1
}


displayConfig() {
	echo "\n${BOLD}Currently configured labels:${RESET}"	

# if a config file was created, show it at the end.
	if [[ -f $configfile ]] 
	then
		column -t -s "=;\"\"" <<< $(defaults read "$configfile" | tr -d "{}()\"")
	else
# if no config was saved, show the results of the discovery process
		for discoveredItem in $configArray
		do
			echo $discoveredItem
		done
		
		echo "\n${BOLD}Ignored Labels:${RESET}"
		for ignoredItem in $ignoredLabelsArray
		do
			echo $ignoredItem
		done
		
		echo "\n${BOLD}Required Labels:${RESET}"
		for requiredItem in $requiredLabelsArray
		do
			echo $requiredItem
		done
		
			
	fi

}



checkInstallomator() {
	
	# check for existence of Installomator to enable installation of updates
	notice "Checking Installomator is installed at ${YELLOW}$InstallomatorPATH ${RESET}"

	if ! [[ -f $InstallomatorPATH ]]
	then
		LatestInstallomator=$(curl --silent --fail "https://api.github.com/repos/Installomator/Installomator/releases/latest" | awk -F '"' "/browser_download_url/ && /pkg\"/ { print \$4; exit }")

		fatal "No Installomator.sh at $InstallomatorPATH. Did you mean to specify a different path?\n\nPatchomator will function normally without it, but will not be able to install updates.\n\nDownload it here:\n\t${YELLOW}$LatestInstallomator${RESET}"
	else
		if [ $($InstallomatorPATH version | cut -d . -f 1) -lt 10 ]
		then
			fatal "Installomator is installed, but is out of date. Version 10 or higher is required for Patchomator to function. You can probably update it with \n\t${YELLOW}sudo Installomator.sh installomator ${RESET}"
		fi
	fi	

}


checkLabels() {
	notice "Path to package labels: ${fragmentsPATH}/labels/"

	# use curl to get the labels - who needs git?
	if [[ ! -d "$fragmentsPATH/labels/" ]]
	then
		if [[ -w "$fragmentsPATH" ]]
		then
			infoOut "Package labels not present at $fragmentsPATH. Attempting to download from https://github.com/installomator/"
			downloadLatestLabels
		else 
			fatal "Package labels not present and $fragmentsPATH is not writable . Re-run patchomator with sudo to download and install them."
		fi
	
	else
		labelsAge=$((($(date +%s) - $(stat -t %s -f %m -- "$fragmentsPATH/labels")) / 86400))

		if [[ $labelsAge -gt 30 ]]
		then
			if [[ -w "${fragmentsPATH}/labels/" ]]
			then
				error "Package labels are out of date. Last updated ${labelsAge} days ago. Attempting to download from https://github.com/installomator/"
				downloadLatestLabels
			else
				fatal "Package labels are out of date. Last updated ${labelsAge} days ago. Re-run patchomator with sudo to update them."
				
			fi
		
		else 
			infoOut "Package labels installed. Last updated ${labelsAge} days ago."
		fi
	fi

}



downloadLatestLabels() {
# gets the latest release version tarball.
# to do: get the latest source available (pre-release)
	latestURL=$(curl -sSL -o - "https://api.github.com/repos/Installomator/Installomator/releases/latest" | grep tarball_url | awk '{gsub(/[",]/,"")}{print $2}') # remove quotes and comma from the returned string
	#eg "https://api.github.com/repos/Installomator/Installomator/tarball/v10.3"

	tarPath="$patchomatorPath/installomator.latest.tar.gz"

	echo "Downloading ${latestURL} to ${tarPath}"
		
	curl -sSL -o "$tarPath" "$latestURL" || fatal "Unable to download. Check ${patchomatorPath} is writable or re-run as root."

	echo "Extracting ${tarPath} into ${patchomatorPath}"
	tar -xz --include='*/fragments/*' -f "$tarPath" --strip-components 1 -C "$patchomatorPath" || fatal "Unable to extract ${tarPath}. Corrupt or incomplete download?"
	touch "${fragmentsPATH}/labels/"
}



caffexit () {
	kill "$caffeinatepid"
	exit $1
}

doInstallations() {

	# No sleeping
	/usr/bin/caffeinate -d -i -m -u &
	caffeinatepid=$!

	# Count errors
	errorCount=0

	# build array of labels from config file
#	labelsArray=($(defaults read $configfile | grep -o -E '\S+\;'))
	IFS=' '

	queuedLabelsArray=("${(@s/ /)labelsArray}")	


	for label in $queuedLabelsArray
	do
		echo "$label"
		
#		label=$(echo $label | cut -d ';' -f1) # trim the trailing semicolon
		echo "Installing ${label}..."
		${InstallomatorPATH} ${label} BLOCKING_PROCESS_ACTION=tell_user NOTIFY=success
		if [ $? != 0 ]; then
			error "Error installing ${label}. Exit code $?"
			let errorCount++
		fi
	done

	echo "Errors: $errorCount"

	caffexit $errorCount

}
 
 
PgetAppVersion() {
	# pkgs contains a version number, then we don't have to search for an app
	if [[ $packageID != "" ]]; then
		
		appversion="$(pkgutil --pkg-info-plist ${packageID} 2>/dev/null | grep -A 1 pkg-version | tail -1 | sed -E 's/.*>([0-9.]*)<.*/\1/g')"
		
		if [[ $appversion != "" ]]; then
			notice "Label: $label_name"
			notice "--- found packageID $packageID installed"
			
			InstalledLabelsArray+=( "$label_name" )
			
			return
		fi
	fi

	if [ -z "$appName" ]; then
		# when not given derive from name
		appName="$name.app"
	fi
	
	# get app in /Applications, or /Applications/Utilities, or find using Spotlight
	notice "Searching system for $appName"
	
	if [[ -d "/Applications/$appName" ]]; then
		applist="/Applications/$appName"
	elif [[ -d "/Applications/Utilities/$appName" ]]; then
		applist="/Applications/Utilities/$appName"
	else
#        applist=$(mdfind "kind:application $appName" -0 )
		applist=$(mdfind "kMDItemFSName == '$appName' && kMDItemContentType == 'com.apple.application-bundle'" -0 )
		# random files named *.app was potentially coming up in the list. Now it has to be an actual app bundle
	fi
	
	appPathArray=( ${(0)applist} )

	if [[ ${#appPathArray} -gt 0 ]]; then
		
		filteredAppPaths=( ${(M)appPathArray:#${targetDir}*} )

		if [[ ${#filteredAppPaths} -eq 1 ]]; then
			installedAppPath=$filteredAppPaths[1]
			
			appversion=$(defaults read $installedAppPath/Contents/Info.plist $versionKey) #Not dependant on Spotlight indexing

			infoOut "Found $appName version $appversion"

			notice "Label: $label_name"
			notice "--- found app at $installedAppPath"
						
			# Is current app from App Store
			if [[ -d "$installedAppPath"/Contents/_MASReceipt ]]
			then
				notice "--- $appName is from App Store. Skipping."
				return
			# Check disambiguation?
			
			else
				verifyApp $installedAppPath
			fi
		fi

	fi


}

verifyApp() {

	appPath=$1
    notice "Verifying: $appPath"

    # verify with spctl
    appVerify=$(spctl -a -vv "$appPath" 2>&1 )
    appVerifyStatus=$(echo $?)
    teamID=$(echo $appVerify | awk '/origin=/ {print $NF }' | tr -d '()' )

    if [[ $appVerifyStatus -ne 0 ]]
    then
        error "Error verifying $appPath"
        return
    fi

    if [ "$expectedTeamID" != "$teamID" ]
    then
    	error "Error verifying $appPath"
    	notice "Team IDs do not match: expected: $expectedTeamID, found $teamID"
        return
    else

# run the commands in current_label to check for the new version string
		newversion=$(zsh << SCRIPT_EOF
declare -A levels=(DEBUG 0 INFO 1 WARN 2 ERROR 3 REQ 4)
currentUser=$currentUser
source "$fragmentsPATH/functions.sh"
${current_label}
echo "\$appNewVersion" 
SCRIPT_EOF
)
	fi

# build array of labels for the config and/or installation

# push label to array
# if in write config mode, writes to plist. Otherwise to an array.
	if [[ -n "$configArray[$appPath]" ]]
	then
		exists="$configArray[$appPath]"

		infoOut "${appPath} already linked to label ${exists}."
		if [[ ${#noninteractive} -eq 1 ]]
		then
			echo "\t${BOLD}Skipping.${RESET}"
			return
		else
			echo -n "${BOLD}Replace label ${exists} with $label_name? ${YELLOW}[y/N]${RESET} "
			read replaceLabel 

			if [[ $replaceLabel =~ '[Yy]' ]]
			then
				echo "\t${BOLD}Replacing.${RESET}"
				configArray[$appPath]=$label_name
				
				if [[ ${#writeconfig} -eq 1 ]]
				then
					/usr/libexec/PlistBuddy -c "set \":${appPath}\" ${label_name}" "$configfile"
				fi
			else
				echo "\t${BOLD}Skipping.${RESET}"
				return
			fi
		fi					
	else
		configArray[$appPath]=$label_name
		if [[ ${#writeconfig} -eq 1 ]]
		then
			/usr/libexec/PlistBuddy -c "add \":${appPath}\" string ${label_name}" "$configfile"
		fi
	fi

	notice "--- Installed version: ${appversion}"
	
	[[ -n "$newversion" ]] && notice "--- Newest version: ${newversion}"

	if [[ "$appversion" == "$newversion" ]]
	then
		notice "--- Latest version installed."
	else
		queueLabel
	fi

}





queueLabel() {
	# add to queue if in install mode
	if [[ ${#installmode} -eq 1 ]]
	then
		labelsArray+="$label_name "
	fi
}

 
 
# You're probably wondering why I've called you all here...


# Command line options

zparseopts -D -E -F -K -- \
-help+=showhelp h+=showhelp \
-install=installmode I=installmode \
-quiet=quietmode q=quietmode \
-yes=noninteractive y=noninteractive \
-verbose=verbose v=verbose \
-read=readconfig r=readconfig \
-write=writeconfig w=writeconfig \
-config:=configfile c:=configfile \
-pathtoinstallomator:=InstallomatorPATH p:=InstallomatorPATH \
-ignored:=ignoredLabels \
-required:=requiredLabels

# -h --help
# -I --install
# -q --quiet
# -y --yes
# -v --verbose
# -r --read
# -w --write
# -c / --config <config file path>
# -p / --pathtoinstallomator <installomator path>


# Show usage
# --help
if [[ ${#showhelp} -gt 0 ]]
then
	usage
fi

notice "Verbose Mode enabled." # and if it's not? This won't echo.

configfile=$configfile[-1] # either provided on the command line, or default
InstallomatorPATH=$InstallomatorPATH[-1] # either provided on the command line, or default /usr/local/Installomator

# ReadConfig mode - read existing plist and display in pretty columns
# skips discovery and all the rest
# --read
if [[ ${#readconfig} -eq 1 ]]
then

	notice "Reading Config"

	if ! [[ -f $configfile ]] 
	then
		fatal "No config file at $configfile. Run patchomator again with ${YELLOW}--write${RESET} to create one now.\n"
	else
		displayConfig
	fi
	exit 0
fi





# 
# 
# if [[ ${#noninteractive} -eq 1 ]]
# then
# 	echo "\n${BOLD}[ ${YELLOW}!!!${RESET}${BOLD} ] Running in non-interactive mode. Check ${configfile} when finished to confirm the correct labels are applied.${RESET}\n"
# fi
# 

# discovery mode
# the main attraction.

# if a config exists, use it
notice "Checking for configuration at ${YELLOW}$configfile ${RESET}"

if [[ ! -f $configfile ]] || [[ ${#writeconfig} -eq 1 ]]
then
	notice "No config file at $configfile. Running discovery."

	# Write Config mode
	# --write

	if [[ ${#writeconfig} -eq 1 ]]
	then
		notice "Writing Config"

		if [[ -d $configfile ]] # common mistake, select a directory, not a filename
		then
			fatal "Please specify a file name for the configuration, not a directory.\n\tExample: ${YELLOW}patchomator --write --config \"/etc/patchomator.plist\""
		fi

		if ! [[ -f $configfile ]] # no existing config
		then
			if [[ -w "$(dirname $configfile)" ]]
			then
				infoOut "No config file at $configfile. Creating one now."
				makepath "$configfile"
				# creates a blank plist
			else
				fatal "$(dirname $configfile) is not writable. Re-run patchomator with sudo to create the config file there, or use a writable path with\n\t ${YELLOW}--config \"path to config file\"${RESET}"
			fi

		else # file exists

			if [[ -w $configfile ]]
			then 
				echo "\t${BOLD}Refreshing $configfile ${RESET}"
			else
				fatal "$configfile is not writable. Re-run patchomator with sudo, or use a writable path with\n\t ${YELLOW}--config \"path to config file\"${RESET}"
			fi	
		
		fi

		/usr/libexec/PlistBuddy -c "clear dict" "${configfile}"
		/usr/libexec/PlistBuddy -c 'add ":IgnoredLabels" array' "${configfile}"	
		/usr/libexec/PlistBuddy -c 'add ":RequiredLabels" array' "${configfile}"	

	fi




	# --required
	if [[ -n "$requiredLabels" ]]
	then
		requiredLabelsArray=("${(@s/ /)requiredLabels[-1]}")	

		for requiredLabel in $requiredLabelsArray
		do
			if [[ -f "${fragmentsPATH}/labels/${requiredLabel}.sh" ]]
			then
				notice "Requiring ${requiredLabel}."

				if [[ ${#writeconfig} -eq 1 ]]
				then
					/usr/libexec/PlistBuddy -c "add \":RequiredLabels:\" string \"${requiredLabel}\"" $configfile		
				fi

				if [[ ${#installmode} -eq 1 ]]
				then
					queueLabel # add to installer queue
				fi
			else
				error "No such label ${requiredLabel}"
			fi
			
		done
	
	fi

	# --ignored
	if [[ -n "$ignoredLabels" ]]
	then
		ignoredLabelsArray=("${(@s/ /)ignoredLabels[-1]}")	

		for ignoredLabel in $ignoredLabelsArray
		do
			if [[ -f "${fragmentsPATH}/labels/${ignoredLabel}.sh" ]]
			then
				notice "Skipping ${ignoredLabel}."
			
				if [[ ${#writeconfig} -eq 1 ]]
				then
					/usr/libexec/PlistBuddy -c "add \":IgnoredLabels:\" string \"${ignoredLabel}\"" $configfile		
				fi
						
			else
				error "No such label ${ignoredLabel}"
			fi
	
		done
	fi





	# can't do discovery without the labels files.
	checkLabels

	# get current user
	currentUser=$(scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ { print $3 }')

	uid=$(id -u "$currentUser")
	
	notice "Current User: $currentUser"
	notice "UID: $uid"

	# start of label pattern
	label_re='^([a-z0-9\_-]*)(\))$'
	#label_re='^([a-z0-9\_-]*)(\)|\|\\)$' 

	# comment
	comment_re='^\#$'

	# end of label pattern
	endlabel_re='^;;'

	targetDir="/"
	versionKey="CFBundleShortVersionString"

	IFS=$'\n'
	in_label=0
	current_label=""


	# MOAR Functions! miscellaneous pieces referenced in the occasional label
	# Needs to confirm that labels exist first.
	source "$fragmentsPATH/functions.sh"

	# for each .sh file in fragments/labels/ strip out the switch/case lines and any comments. 

	for labelFragment in "$fragmentsPATH"/labels/*.sh; do 

		labelFile=$(basename -- "$labelFragment")
		labelFile="${labelFile%.*}"
	
		if [[ $ignoredLabelsArray =~ ${labelFile} ]]
		then
			notice "Ignoring label $labelFile."
			continue # we're done here. Move along.
		fi
	
		infoOut "Processing label $labelFile."

		exec 3< "${labelFragment}"

		while read -r -u 3 line; do 

			# strip spaces and tabs 
			scrubbedLine="$(echo $line | sed -E 's/^( |\t)*//g')"
		
			if [ -n $scrubbedLine ]; then

				if [[ $in_label -eq 0 && "$scrubbedLine" =~ $label_re ]]; then
				   label_name=${match[1]}
				   in_label=1
				   continue # skips to the next iteration
				fi

				if [[ $in_label -eq 1 && "$scrubbedLine" =~ $endlabel_re ]]; then 
					# label complete. A valid label includes a Team ID. If we have one, we can check for installed
					[[ -n $expectedTeamID ]] && PgetAppVersion

					in_label=0
					packageID=""
					name=""
					appName=""
					expectedTeamID=""
					current_label=""
					appNewVersion=""

					continue # skips to the next iteration
				fi

				if [[ $in_label -eq 1 && ! "$scrubbedLine" =~ $comment_re ]]; then
			# add the label lines to create a "subscript" to check versions and whatnot
			# if empty, add the first line. Otherwise, you'll get a null line
					[[ -z $current_label ]] && current_label=$line || current_label=$current_label$'\n'$line

					case $scrubbedLine in

					  'name='*|'packageID'*|'expectedTeamID'*)
						  eval "$scrubbedLine"
					  ;;

					esac
				fi
			fi
		done
	done
	
else
# read existing config. One label per line. Send labels to Installomator for updates.
	infoOut "Existing config found at $configfile."
fi	
# end discovery	
	
	
# install mode. Requires root and Installomator, checks for existing config. 
# --install

if [[ ${#installmode} -eq 1 ]]
then

	# can't install without the 'mator
	checkInstallomator	

	# Check your privilege
	if ! $IAMROOT
	then
		fatal "Install mode must be run with root/sudo privileges. Re-run Patchomator with\n\t ${YELLOW}sudo zsh patchomator.sh --install${RESET}"
	fi
	
	infoOut "Passing labels to Installomator."

	doInstallations

	exit 0

fi

# end install mode




echo "${BOLD}Done.${RESET}\n"

displayConfig





# OfferToInstall() {
# 		#Check your privilege
# 		if $IAMROOT
# 		then
# 			echo -n "${BOLD}Download and install it now? ${YELLOW}[y/N]${RESET} "
# 			[[ ${#noninteractive} -eq 1 ]] || read DownloadFromGithub
# 	
# 			if [[ $DownloadFromGithub =~ '[Yy]' ]]
# 			then
# 				installInstallomator
# 			else
# 				echo "${BOLD}Continuing without Installomator.${RESET}"
# 				NoInstall=true
# 			fi
# 		else
# 			echo "Specify a path with \"${YELLOW}-p [path to Installomator]${RESET}\" or download and install it from here:\
# 			\n\t ${YELLOW}https://github.com/Installomator/Installomator${RESET}\
# 			\n\nThis script can also attempt to install Installomator for you. Re-run patchomator as root with\
# 			\n\t ${YELLOW}sudo zsh patchomator.sh${RESET}"	
# 		
# 			echo -n "${BOLD}Continue without installing Installomator? ${YELLOW}[Y/n] ${RESET}"
# 			[[ ${#noninteractive} -eq 1 ]] || read ContinueWithout
# 	
# 			if [[ $ContinueWithout =~ '[Nn]' ]]; then
# 				echo "Okay."
# 				exit 0
# 			else
# 				echo "${BOLD}Continuing without Installomator.${RESET}"
# 				NoInstall=true
# 			fi
# 	
# 		fi
# }

# installInstallomator() {
# 	# Get the URL of the latest PKG From the Installomator GitHub repo
# 	PKGurl=$(curl --silent --fail "https://api.github.com/repos/Installomator/Installomator/releases/latest" | awk -F '"' "/browser_download_url/ && /pkg\"/ { print \$4; exit }")
# 	# Expected Team ID of the downloaded PKG
# 	expectedTeamID="JME5BW3F3R"
# 
# 	tempDirectory=$( mktemp -d )
# 	notice "Created working directory '$tempDirectory'"
# 	# Download the installer package
# 	notice "Downloading Installomator package"
# 	curl --location --silent "$PKGurl" -o "$tempDirectory/Installomator.pkg"
# 
# 	# Verify the download
# 	teamID=$(spctl -a -vv -t install "$tempDirectory/Installomator.pkg" 2>&1 | awk '/origin=/ {print $NF }' | tr -d '()')
# 	notice "Team ID for downloaded package: $teamID"
# 
# 	# Install the package if Team ID validates
# 	if [ "$expectedTeamID" = "$teamID" ] || [ "$expectedTeamID" = "" ]; then
# 		notice "Package verified. Installing package Installomator.pkg"
# 		if ! installer -pkg "$tempDirectory/Installomator.pkg" -target / -verbose
# 		then
# 			fatal "Installation failed. See /var/log/installer.log for details."
# 		fi
# 			
# 	else
# 		fatal "Package verification failed before package installation could start. Download link may be invalid. Aborting."
# 	fi
# 
# 	# Remove the temporary working directory when done
# 	notice "Deleting working directory '$tempDirectory' and its contents"
# 	rm -Rf "$tempDirectory"
# 
# }

