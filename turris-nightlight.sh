#!/usr/bin/env sh

# Copyright (c) 2018 Jan Wrona
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.


# Turris-nighlight is a program for the Turris router to set its LED intensity
# according the current time period (nighttime, morning twilight, daytime,
# evening twilight). The intensity is set to the minimal value during nighttime,
# to the maximal value during daytime, gradually increased during morning
# twilight, and gradually decreased during evening twilight.
#
# The start and end points of the mentioned time periods vary, based on factors
# such as season, latitude, longitude, and time zone. Turris-nightlight uses a
# web API (http://api.sunrise-sunset.org/) to obtain these time points. If
# geographic coordinates are not supplied as command-line arguments, the
# coordinates are obtained by an IP geolocation service. A query to a web IP
# geolocation API (http://ip-api.com/) will be performed, which will use your
# current IP address (as seen by the API).


# Sunrise/sunset is the instant at which the upper edge of the Sun
# appears/disappears over the horizon in the morning/evening as a result of
# Earth's rotation. Dawn is the time that marks the beginning of morning
# twilight before sunrise. Dusk occurs at the very end of evening twilight after
# sunset and just before night. Twilight is that period of dusk after sunset or
# dawn before sunrise during which the sky is partially lit by atmospheric
# scattering of sunlight. The duration of twilight after sunset or before
# sunrise depends on atmospheric conditions (clouds, dust, air pressure,
# temperature, humidity) and on the parallactic angle (the angle between the
# path of the setting or rising sun and the local horizon), both of which vary
# with the seasons (specifically the solar declination) and the terrestrial
# latitude. There are three types of dawn/dusk: astronomical, nautical, and
# civil. Astronomical dawn is the point at which it becomes possible to detect
# light in the sky, when the sun is 18 degrees below the horizon. Nautical dawn
# occurs at 12 degrees below the horizon, when it becomes possible to see the
# horizon properly and distinguish some objects. Civil dawn occurs when the sun
# is 6 degrees below the horizon and there is enough light for activities to
# take place without artificial lighting.


# ShellCheck related stuff:
# Ignore SC2039 (in POSIX sh, 'local' is undefined). However, even the most
# primitive POSIX-compliant shells (including ash) support it.
# shellcheck disable=SC2039


set -eu

export LC_ALL=C

PROGRAM_NAME="$(basename "$0")"
readonly PROGRAM_NAME


################################################################################
# $1 is severity level err|warn|info, the rest is the message
log() {
    local SYSLOG_SEVERITY_LEVEL SEVERITY_KEYWORD

    case "$1" in
    err)
        SYSLOG_SEVERITY_LEVEL=3
        SEVERITY_KEYWORD="Error"
        ;;
    warn)
        SYSLOG_SEVERITY_LEVEL=4
        SEVERITY_KEYWORD="Warning"
        ;;
    info)
        SYSLOG_SEVERITY_LEVEL=6
        SEVERITY_KEYWORD="Info"
        ;;
    *)
        echo "Error: invalid severity level '$1'" >&2
        exit 1
    esac
    shift  # shift the severity level

    case "$LOG_DEVICE" in
    syslog)
        logger -t "$PROGRAM_NAME" -p "$SYSLOG_SEVERITY_LEVEL" "$@"
        ;;
    stderr)
        echo "$SEVERITY_KEYWORD:" "$@" >&2
        ;;
    *)
        echo "Error: invalid logging device '$LOG_DEVICE'" >&2
        exit 1
    esac
}

# Print error message and exit.
die() {
    log err "$@"
    exit 1
}


################################################################################
# Set LED intensity according to the supplied timestamp.
set_intensity() {
    local NOW_UNIX="$1"
    local INTENSITY

    if [ "$NOW_UNIX" -lt "$DAWN_UNIX" ]; then
        [ -n "$VERBOSE" ] && log info "current time period: nighttime before dawn"
        INTENSITY="$LED_INTENSITY_MIN"
    elif [ "$NOW_UNIX" -lt "$SUNRISE_UNIX" ]; then
        [ -n "$VERBOSE" ] && log info "current time period: morning twilight"
        # morning twilight
        SECONDS_SINCE_DAWN="$((NOW_UNIX - DAWN_UNIX))"
        INTENSITY="$((LED_INTENSITY_MIN + \
            (SECONDS_SINCE_DAWN * LED_INTENSITY_RANGE / MORNING_TWILIGHT_DUR)))"
    elif [ "$NOW_UNIX" -lt "$SUNSET_UNIX" ]; then
        [ -n "$VERBOSE" ] && log info "current time period: daytime"
        INTENSITY="$LED_INTENSITY_MAX"
    elif [ "$NOW_UNIX" -lt "$DUSK_UNIX" ]; then
        [ -n "$VERBOSE" ] && log info "current time period: evening twilight"
        SECONDS_UNTIL_DUSK="$((DUSK_UNIX - NOW_UNIX))"
        INTENSITY="$((LED_INTENSITY_MIN + \
            (SECONDS_UNTIL_DUSK * LED_INTENSITY_RANGE / EVENING_TWILIGHT_DUR)))"
    else
        [ -n "$VERBOSE" ] && log info "current time period: nighttime after dusk"
        INTENSITY="$LED_INTENSITY_MIN"
    fi

    [ -n "$VERBOSE" ] && log info "setting intensity to $INTENSITY"

    if [ -n "$DRY_RUN" ]; then
        log info "would execute 'rainbow intensity $INTENSITY'"
    else
        rainbow intensity "$INTENSITY"
    fi
}

# Unit test for the set_intensity function.
test_set_intensity() {
    local FIRST LAST INC I
    FIRST="$(date -d "$(date -I)" +%s)"  # today midnight
    LAST="$((FIRST + 60 * 60 * 24 - 1))"  # last second of today
    INC=10  # 10 seconds step
    for I in $(seq "$FIRST" "$INC" "$LAST"); do
        log info "testing set_intensity for $(date -d "@$I"):"
        set_intensity "$I"
    done
}


################################################################################
# Naive approach to extract ISO 8601 date formatted value with the specified key
# from the JSON API response.
times_api_response_extract() {
    local ISO8601_REGEX='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+00:00'
    echo "$1" | grep -Eo "\"$2\":\"$ISO8601_REGEX\"" | cut -d : -f 2- | tr -d \"
}

# Return the supplied ISO 8601 datetime string as seconds since
# 1970-01-01 00:00:00 UTC. BusyBox's date does not recognize the ISO 8601 format
# YYYY-MM-DDThh:mm:ss+hh:mm, thus the need to remove the offset.
date_iso_to_unix() {
    NO_OFFSET="$(echo "$1" | cut -d + -f 1 | tr "T" " ")"
    date -u -d "$NO_OFFSET" +%s  # input datetime is in UTC
}

# Perform a query to the times API and create a new cache file based on the
# valued from the response. The API response is in form of the following JSON
# document. All dates and times are in UTC represented in the ISO 8601 format.
# {
#     "results":
#     {
#         "sunrise":"2018-05-03T03:27:40+00:00",
#         "sunset":"2018-05-03T18:13:04+00:00",
#         "solar_noon":"2018-05-03T10:50:22+00:00",
#         "day_length":53124,
#         "civil_twilight_begin":"2018-05-03T02:51:28+00:00",
#         "civil_twilight_end":"2018-05-03T18:49:16+00:00",
#         "nautical_twilight_begin":"2018-05-03T02:05:04+00:00",
#         "nautical_twilight_end":"2018-05-03T19:35:40+00:00",
#         "astronomical_twilight_begin":"2018-05-03T01:09:33+00:00",
#         "astronomical_twilight_end":"2018-05-03T20:31:11+00:00"
#     },
#     "status":"OK"
# }
times_api_query() {
    log info "times API: cache file does not exit/is invalid/is outdated," \
             "performing a query"

    local RESPONSE
    RESPONSE="$(curl -sS "$URI")" || die "times API: failed to fetch"
    RESPONSE="$(echo "$RESPONSE" | tr -d ' \n\t')"
    if ! echo "$RESPONSE" | grep '^{"results":{[^}]*},"status":"OK"}$' >/dev/null
    then
        die "times API: invalid response '$RESPONSE'"
    fi

    local DAWN_ISO SUNRISE_ISO SUNSET_ISO DUSK_ISO
    DAWN_ISO="$(times_api_response_extract "$RESPONSE" \
                                           "${TWILIGHT_TYPE}_twilight_begin")"
    SUNRISE_ISO="$(times_api_response_extract "$RESPONSE" "sunrise")"
    SUNSET_ISO="$(times_api_response_extract "$RESPONSE" "sunset")"
    DUSK_ISO="$(times_api_response_extract "$RESPONSE" \
                                           "${TWILIGHT_TYPE}_twilight_end")"

    printf '%s\n%s,%s,%s,%s\n' "$QUERY" "$(date_iso_to_unix "$DAWN_ISO")" \
        "$(date_iso_to_unix "$SUNRISE_ISO")" \
        "$(date_iso_to_unix "$SUNSET_ISO")" \
        "$(date_iso_to_unix "$DUSK_ISO")" \
        >"$CACHE_FILE"
}

# Set DAWN_UNIX, SUNRISE_UNIX, SUNRISE_UNIX, and DUSK_UNIX variables to
# appropriate today's values. If the API response cache file exists and is valid
# for the current parameters, use the values from the file. Otherwise, perform a
# query to the API.
get_todays_times() {
    local CACHE_FILE DATE_TODAY QUERY URI RESPONSE
    CACHE_FILE="/tmp/turris-nightlight"
    DATE_TODAY="$(date -I)"  # local date in YYYY-MM-DD
    QUERY="lat=${LAT}&lng=${LONG}&formatted=0&date=${DATE_TODAY}"
    URI="http://api.sunrise-sunset.org/json?${QUERY}"

    if ! [ -f "$CACHE_FILE" ] || ! [ "$(head -1 "$CACHE_FILE")" = "$QUERY" ]
    then
        times_api_query
    fi

    local TIMES_CSV COMMAS
    TIMES_CSV="$(tail -n 1 "$CACHE_FILE")"
    COMMAS="$(echo "$TIMES_CSV" | tr -cd ",")"
    [ ${#COMMAS} -ne 3 ] && die "invalid cache file"

    DAWN_UNIX="$(echo "$TIMES_CSV" | cut -d , -f 1)"
    SUNRISE_UNIX="$(echo "$TIMES_CSV" | cut -d , -f 2)"
    SUNSET_UNIX="$(echo "$TIMES_CSV" | cut -d , -f 3)"
    DUSK_UNIX="$(echo "$TIMES_CSV" | cut -d , -f 4)"
}

# Perform a query to the IP geolocation API (http://ip-api.com/). It is
# possible to supply an IP address or domain to lookup, but without one it will
# use your current IP address (as seen by the API).
ip_geolocation_api_query() {
    local URI RESPONSE STATUS

    [ -n "$VERBOSE" ] && log info "geo API: unknown latitude or longitude," \
                                  "using an IP geolocation information"
    URI='http://ip-api.com/csv?fields=status,lat,lon'
    RESPONSE="$(curl -sS "$URI")" || die "geo API: failed to fetch"

    [ -z "$RESPONSE" ] && die "geo API: empty response"
    IFS=, read -r STATUS LAT LONG <<EOF
$RESPONSE
EOF

    [ "$STATUS" != "success" ] && die "geo API: $STATUS"
    readonly LAT LONG
}

################################################################################
# Print an usage string.
print_usage() {
    cat <<END
Usage: $0 [--lat LATITUDE] [--long LONGITUDE]
          [--min INTENSITY] [--max INTENSITY] [--twilight TWILIGHT_TYPE]
          [--log LOGGING_DEVICE] [-v] [-n] [-h] [-u]
END
}

# Print a help string.
print_help() {
    cat <<END
Turris-nighlight is a program for the Turris router to set its LED intensity
according the current time period (nighttime, morning twilight, daytime,
evening twilight). The intensity is set to the minimal value during nighttime,
to the maximal value during daytime, gradually increased during morning
twilight, and gradually decreased during evening twilight.

The start and end points of the mentioned time periods vary, based on factors
such as season, latitude, longitude, and time zone. Turris-nightlight uses a
web API (http://api.sunrise-sunset.org/) to obtain these time points. If
geographic coordinates are not supplied as command-line arguments, the
coordinates are obtained by an IP geolocation service. A query to a web IP
geolocation API (http://ip-api.com/) will be performed, which will use your
current IP address (as seen by the API).
END
echo
print_usage
echo
cat <<END
--lat LATITUDE    Latitude (a geographic coordinate) in the WGS84 Decimal
                  Degrees format.

--long LONGITUDE  Longitude (a geographic coordinate) in the WGS84 Decimal
                  Degrees format.

--min INTENSITY   Minimal LED intensity as an integer ranging from 0 to 100
                  (percent of minimal brightness). Has to be less than or equal
                  to the maximal LED intensity.
                  Default: 0.

--max INTENSITY   Maximal LED intensity as an integer ranging from 0 to 100
                  (percent of maximal brightness). Has to be greater than or
                  equal to the minimal LED intensity.
                  Default: 100.

--twilight TWILIGHT_TYPE
                  Twilight/dawn/dusk type: civil, nautical, or astronomical.
                  Default: civil.

--log LOGGING_DEVICE
                  Where to print diagnostic messages: stderr or syslog.
                  Default: stderr.

-v, --verbose     Be more verbose.

-n, --dry-run     Do not actually set the intensity, just show what would be
                  executed.

-h, --help        Print this help message and exit.

-u, --usage       Print an usage string and exit.
END
}

# Set default values and parse command-line arguments.
parse_args() {
    # no default coordinates
    LAT=""
    LONG=""

    # default LED intensity range is the full range
    LED_INTENSITY_MIN=0
    LED_INTENSITY_MAX=100

    # civil or nautical or astronomical
    TWILIGHT_TYPE="civil"

    # logs go to stderr by default
    LOG_DEVICE_ARG=""
    LOG_DEVICE="stderr"

    # dry run and verbose modes disabled by default
    DRY_RUN=""
    VERBOSE=""

    # disable the test by default
    TEST=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
        # mandatory options
        --lat)
            [ "$#" -gt 1 ] || die "missing argument for option '--lat'"
            LAT="$2"
            shift 2
            ;;
        --long)
            [ "$#" -gt 1 ] || die "missing argument for option '--long'"
            LONG="$2"
            shift 2
            ;;

        # optional options
        --min)
            [ "$#" -gt 1 ] || die "missing argument for option '--min'"
            LED_INTENSITY_MIN="$2"
            shift 2
            ;;
        --max)
            [ "$#" -gt 1 ] || die "missing argument for option '--max'"
            LED_INTENSITY_MAX="$2"
            shift 2
            ;;
        --twilight)
            [ "$#" -gt 1 ] || die "missing argument for option '--twilight'"
            TWILIGHT_TYPE="$2"
            shift 2
            ;;

        --log)
            [ "$#" -gt 1 ] || die "missing argument for option '--log'"
            LOG_DEVICE_ARG="$2"  # setting LOG_DEVICE now is dangerous
            shift 2
            ;;
        -v|--verbose)
            VERBOSE="true"
            shift
            ;;
        -n|--dry-run)
            DRY_RUN="true"
            shift
            ;;
        -h|--help)
            print_help
            exit
            ;;
        -u|--usage)
            print_usage
            exit
            ;;

        # undocumented
        --test)
            TEST="true"
            shift
            ;;

        *)  # unknown option
            die "unknown option '$1'"
            ;;
        esac
    done

    readonly LED_INTENSITY_MIN LED_INTENSITY_MAX TWILIGHT_TYPE
}

# Return true if $1 is a positive integer, false otherwise.
is_positive_integer() {
    case "$1" in
        ""|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# Check validity of command-line arguments.
check_args() {
    is_positive_integer "$LED_INTENSITY_MIN" \
        || die "minimal LED intensity is not a positive integer"
    is_positive_integer "$LED_INTENSITY_MIN" \
        || die "maximal LED intensity is not a positive integer"

    [ "$LED_INTENSITY_MIN" -gt 100 ] \
        && die "minimal LED intensity is greater than 100"
    [ "$LED_INTENSITY_MAX" -gt 100 ] \
        && die "maximal LED intensity is greater than 100"
    readonly LED_INTENSITY_RANGE=$((LED_INTENSITY_MAX - LED_INTENSITY_MIN))
    [ "$LED_INTENSITY_RANGE" -lt 0 ] && die "negative LED intensity range"

    case "$TWILIGHT_TYPE" in
        civil|nautical|astronomical) ;;
        *) die "invalid twilight type '$TWILIGHT_TYPE'" ;;
    esac

    case "$LOG_DEVICE_ARG" in
        "")  # logging device not set, keep the default
            ;;
        stderr|syslog)
            LOG_DEVICE="$LOG_DEVICE_ARG"
            ;;
        *)
            die "invalid logging device '$LOG_DEVICE_ARG'"
            ;;
    esac
    readonly LOG_DEVICE
}


################################################################################
# Main function.
main() {
    parse_args "$@"
    check_args

    if [ -z "$LAT" ] || [ -z "$LONG" ]; then
        # latitude or longitude not supplied, use the IP geolocation API
        ip_geolocation_api_query
    fi

    get_todays_times

    MORNING_TWILIGHT_DUR=$((SUNRISE_UNIX - DAWN_UNIX))
    [ "$MORNING_TWILIGHT_DUR" -le 0 ] && die "sunrise before dawn"
    EVENING_TWILIGHT_DUR=$((DUSK_UNIX - SUNSET_UNIX))
    [ "$EVENING_TWILIGHT_DUR" -le 0 ] && die "dusk dusk before sunset"

    local NOW_UNIX
    NOW_UNIX="$(date +%s)"
    if [ -n "$VERBOSE" ]; then
        log info "latitude:  $LAT"
        log info "longitude: $LONG"
        log info "now:       $(date -d "@$NOW_UNIX")"
        log info "dawn:      $(date -d "@$DAWN_UNIX")"
        log info "sunrise:   $(date -d "@$SUNRISE_UNIX")"
        log info "sunset:    $(date -d "@$SUNSET_UNIX")"
        log info "dusk:      $(date -d "@$DUSK_UNIX")"
        log info "morning twilight duration: $MORNING_TWILIGHT_DUR seconds"
        log info "evening twilight duration: $EVENING_TWILIGHT_DUR seconds"
    fi

    if [ -n "$TEST" ]; then
        test_set_intensity
    else
        set_intensity "$NOW_UNIX"
    fi
}

main "$@"
