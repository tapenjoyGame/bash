#!/bin/bash

#####
# 2013-03-04 / GPLv3 / Keesing Games B.V.
#####
# This script fetches the CSV exceptionLogs from Flurry (which are limited to 15 rows per file)
#   and concatenate them into one CSV file.
# It checks the validity of the CSV and re-download it if it seems invalid 
#   (flurry has an anti-bot "feature" that denies access when too many requests happen in little time)
# It also takes care of converting the dates (in the CSV) to the appropriate timezone.
#####
# Inspired from :
# http://chomptech.wordpress.com/2010/03/22/getting-access-to-your-flurry-exception-logs/
#####
# TODO :
#   - Fix date 12:45:35 AM => 00:45:25 AM
#   - Get rid of LIMIT (then take care what kind of error makes "the CSV seems invalid")
#   - Make the 2 sleep timers more random-ish (with an increment on failure?)
#   - arguments to overwrite configs (make date conv optional, specify target file)
#####

## Config
EMAIL=''
PASSWORD=''
PROJECT=''
LIMIT=1000
DEBUG=false

## Consts
outFile="$(pwd)/exceptions.csv"
csvHeader='Timestamp,Index,Error,Message,Version,Error ID,Method, Platform'
dateConvTimeZone='Europe/Amsterdam'
dateConvFormat='+%m/%d/%y %I:%M:%S %p %Z'
urlBase="https://dev.flurry.com/exceptionLogsCsv.do?projectID=${PROJECT}&versionCut=versionsAll&intervalCut=allTime&stream=true"
urlLogin='https://dev.flurry.com/secure/loginAction.do'
now=$(date +%Y%m%d.%H%M%S)

## Functions
# Wrapper for output handling
function log(){
    time=$(date '+%Y-%m-%d %T')
    type="$1"

    if [ "$type" == "DEBUG" ] && [ $DEBUG != true ]; then
        return
    fi

    shift
    echo "[$time] [$type] $*"
}

# Wrapper for clean exit on error : log error, cleanup and exit 1
function error(){
    if [ ! -z "$1" ]; then
        log "FATAL" "$1"
    fi

    local_cleanup

    log "DEBUG" "Exiting with status 1"

    exit 1
}

# Cleanup local folders
function local_cleanup(){
    if [ -e "$tmpDir" ]; then
        log "INFO" "Removing tmpDir"
        rm -rf $tmpDir
    fi
}

## The fun part

# Check username/password
if [ "${EMAIL}" == '' ] || [ "${PASSWORD}" == '' ] || [ "${PROJECT}" == '' ]; then
    error 'Email and/or password and/or projectID is empty. Please edit the "Config" part at the beginning of this script.'
fi

# Prepare the outfile
log 'INFO' "Will write output to ${outFile}"
if [ -f "${outFile}" ]; then
    echo > "${outFile}" || error "Could not truncate the output file ${outFile}"
else
    touch "${outFile}" || error "Could not create the output file ${outFile}"
fi

# Make temp dirs / files
log 'DEBUG' 'Creating temp directories/files'

tmpDir=$(mktemp --directory --tmpdir "$(basename $0).${now}.XXXXXXXXXX") || error 'Could not create temporary directory'
tmpCsv=$(mktemp --tmpdir="$tmpDir" flurry.cookiejar.XXXXXXXX) || error 'Could not create temporary CSV'
cookieJar=$(mktemp --tmpdir="$tmpDir" flurry.cookiejar.XXXXXXXX) || error 'Could not create temporary cookie jar'

log 'DEBUG' "    tmpDir    : $tmpDir"
log 'DEBUG' "    tmpDir    : $tmpCsv"
log 'DEBUG' "    cookieJar : $cookieJar"

# url encode email & password
log 'DEBUG' 'Urlencoding user/pass'

user=$(/usr/bin/php -r "echo urlencode(\"${EMAIL}\");")
pass=$(/usr/bin/php -r "echo urlencode(\"${PASSWORD}\");")

# Get session
log 'INFO' 'Logging into flurry'
log 'DEBUG' "    url : ${urlLogin}"
curl --cookie-jar "${cookieJar}" \
        --data "loginEmail=${user}&loginPassword=${pass}&rememberMe=true&__checkbox_rememberMe=true" \
        --insecure "${urlLogin}" || error 'Error while logging in!'

# Download each CSV of 15 lines
log 'INFO' 'Downloading CSVs'
offset=0
counter=1
while [ "$offset" -lt "$LIMIT" ]; do
    log 'INFO' "Processing request #${counter} (offset ${offset})"

    # Build the URL
    url="${urlBase}&direction=1&offset=${offset}"
    log 'DEBUG' "Url : ${url}"

    # Request the CSV
    curl --cookie ${cookieJar} \
            --location "${url}" \
            --output "${tmpDir}/exception${counter}.csv" &> /dev/null  || error 'Error while retrieving/saving the CSV'

    # Check the CSV (can you find the header in it?)
    more "${tmpDir}/exception${counter}.csv" | grep "$csvHeader" &> /dev/null 
    if [ "$?" -ne 0 ]; then
        # CSV seems invalid, so decrement the counters to try the same CSV again
        log 'WARNING' "The result for request #${counter} seems invalid. Retrying."
        offset=$((${offset}-15))
        counter=$((${counter}-1))

        # Wait some time so that flurry doesn't nag
        sleep 20
    else
        # CSV seems valid, copy it to the final CSV (with our without CSV headers)
        if [ "$offset" -eq 0 ]; then
            cp "${tmpDir}/exception${counter}.csv" "${tmpCsv}" || error "Could not write to ${tmpCsv}"
        else
            tail --lines=+2 "${tmpDir}/exception${counter}.csv" >> "${tmpCsv}" || error "Could not write to ${tmpCsv}"
        fi

        # Add a blank line at the end of the final CSV
        echo >> "${tmpCsv}" || error "Could not write to ${tmpCsv}"
    fi

    # Wait some time so that flurry doesn't nag
    sleep 5

    # Increment the counters
    offset=$((${offset}+15))
    counter=$((${counter}+1))
done

# Convert all dates to CET time
log 'INFO' "Converting CSV dates to use TimeZone '${dateConvTimeZone}'"
totalLines=$(more "$tmpCsv" | wc -l)
i=0
while read line ; do
    [[ $(echo "scale=2; $i/100" | bc) =~ ^-?[0-9]*\.00$ ]] && log 'INFO' "Processed $i out of $totalLines"

    if [ $i -eq 0 ]; then
        # Do not process CSV header
        echo "${line}" >> "${outFile}"
    else
        # Extract date
        date=$(echo "$line" | sed -e 's/",".*//' -e 's/"//')

        # Convert it
        cDate=$(TZ="$dateConvTimeZone" date --date="$date" "$dateConvFormat")

        log 'DEBUG' "$date => $cDate"

        # Rewrite the line with the converted date
        echo -n "\" $cDate \"" >> "${outFile}"
        echo $(echo "$line" | sed -e "s_${date}__" -e 's/""//') >> "${outFile}"

    fi
    i=$((i+1))
done < "$tmpCsv"

#clean up
local_cleanup

# Exit properly
log 'INFO' 'Done!'
exit 0
