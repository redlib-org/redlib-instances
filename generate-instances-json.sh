#!/usr/bin/env bash

# generate-instances-json.sh
#
# Generate a JSON of Libreddit instances, given a CSV input listing those
# instances.
#
# Information on script options is available by running
#     generate-instances.sh -h
#
# For more information on how to use this script, see README.md.
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# this program. If not, see <https://www.gnu.org/licenses/>. 

set -o pipefail

# Grab today's date.
TODAY="$(date -I -u)"

# List of programs on which this script depends.
# curl is required in order to make HTTP requests.
# jq is required for JSON processing.
DEPENDENCIES=(curl jq)

# This is the default User-Agent the script will tell curl to use if the
# environment variable USER_AGENT is not defined.
DEFAULT_USER_AGENT="libreddit-instance-updater/0.1"

# If USER_AGENT is specified in the envs, we'll pass this argument to curl
# using the -A flag to set a custom User-Agent.
USER_AGENT="${USER_AGENT:-${DEFAULT_USER_AGENT}}"

# HTTP proxy for connecting to nodes on I2P. This is an environment variable.
I2P_HTTP_PROXY="${I2P_HTTP_PROXY:-}"

# check_tor
#
# Returns true if tor is running; false otherwise.
check_tor ()
{
    pidof -q tor
}

# check_bin
#
# Returns true if the specified program is in PATH; false otherwise.
check_program ()
{
    command -v "${1}" >/dev/null
}

# can_tor
#
# Returns true if tor is running
can_tor ()
{
    check_tor
}

# can_i2p
#
# Returns true if an I2P HTTP proxy is specified.
can_i2p ()
{
    [[ -n "${I2P_HTTP_PROXY}" ]]
}

# check_dependencies
#
# Returns false if a script dependency is missing. If this is the case, each
# missing dependency will be printed to stdout.
check_dependencies ()
{
    local -i rc=0

    for dep in "${DEPENDENCIES[@]}"
    do
        if ! check_program "${dep}"
        then
            rc=1
            echo "${dep}"
        fi
    done

    return "${rc}"
}

# read_csv_row [-d DELIMITER] [-v] ROW
#
# Reads a row of comma-separated values. Each value is printed as a separate
# line to stdout. The function prints nothing and returns 1 if the row is
# malformed, or if no ROW argument was passed to the function.
#
# The default delimiter is ','. Option -d can change this delimiter to a
# different character.
#
# Option -v will print "$i: " before each value, where $i starts at 1 and
# represents the value's position in the row.
#
# It is assumed that the total input is a row, which may include \n (if it's
# in, say, a quoted value).
#
# This will increment the value of the global variable POSITION by
# how many characters has been read.
read_csv_row ()
{
    local opt=
    local OPTIND
    local OPTARG
    
    local -i i=0
    local -i quote=0
    local -i esc=0
    local -i seen_delim=0
    local row=
    local print_col=n
    local len=
    local char=
    local value=
    local -a values=()
    local delim=,

    while getopts "d:v" opt
    do
        case "${opt}" in
        d) delim="${OPTARG}" ;;
        v) print_col="y" ;;
        *) ;;
        esac
    done
    shift "$((OPTIND-1))"

    # Get row from arg.
    row="${1}"
    if [[ -z "${1}" ]]
    then
        return 1
    fi

    # Process row character by character.
    len="${#row}"

    value=
    for (( i = 0; i < len; i++ ))
    do
        char="${row:${i}:1}"
       
        # "Handle" escapes. Really, it just means writing the escape verbatim
        # into the string. Yes, that includes ". Because this is ultimately
        # going into JSON, and making this a fully-featured CSV reader would
        # be beyond the scope of for what this script is intended.
        if [[ ${esc} -eq 1 ]]
        then
            esc=0
            value+="\\${char}"

            # Escape handled. Move on to next character.
            continue
        fi
        
        # \ triggers escape.
        # shellcheck disable=SC1003
        if [[ "${char}" == '\' ]]
        then
            esc=1
            continue
        fi

        # A delimiter means the end of the value (assuming we're not in a
        # quote).
        if [[ ${quote} -eq 0 && "${char}" == "${delim}" ]]
        then
            IFS=$'\n' values+=("${value}")
            value=
            seen_delim=1
            continue
        fi

        # " means the value is quoted, assuming we're not in the middle of an
        # escape.
        if [[ ${esc} -eq 0 && "${char}" == '"' ]]
        then
            quote=$(( (quote + 1) % 2 ))

            # We don't actually want to include the double quote in the value.
            continue
        fi

        # This character isn't a delimier, so switch off seen_delim.
        seen_delim=0

        value+="${char}"
    done

    # Handle unexpected end of row.
    if [[ ${quote} -eq 1 || ${esc} -eq 1 ]]
    then
        return 1
    fi

    # Add the final value to the list of values.
    if [[ (${seen_delim} -eq 0 && -n "${value}") || (${seen_delim} -eq 1 && -z "${value}") ]]
    then
        values+=("${value}")
    fi

    # Print each value in a separate line.
    i=1
    for value in "${values[@]}"
    do
        if [[ "${print_col}" == "y" ]]
        then
            echo -n "${i}: "
            (( i++ ))
        fi
        echo "${value}"
    done
}

# canonicalize_url URL
#
# Performs the following transformations of the given URL:
#     -- Converts the string to all-lowercase.
#     -- Removes any trailing slashes, but only if the path is /.
#
# Returns 1 if no or a blank URL is provided, or 2 if the string is not a
# valid url.
#
# TODO: Internationalized domain name support. For now, provide the URL in
# Punycode if needed.
canonicalize_url ()
{
    local url=

    if [[ -z "${1}" ]]
    then
        return 1
    fi
    url="${1}"
    
    # Convert URL to lowercase.
    url="${url,,}"

    # Reject the string if it's not a valid URL.
    if [[ ! "${url}" =~ ^[a-z0-9]+://[a-z0-9\.\-]+/? ]]
    then
        return 2
    fi
    
    # Strip leading /, but only if the path is /.
    if [[ "${url#*://*/}" =~ ^/*$ ]]
    then
        while [[ "${url: -1:1}" == "/" ]]
        do
            url="${url:0: -1}"
        done
    fi

    echo "${url}"
}

# get [-T] URL
#
# Makes an HTTP(S) GET equest to the provided URL with curl. The response is
# written to standard out. get will determine if the URL is an onion site, and,
# if so, it wrap the curl call with socks proxy. If the URL is a I2P site, and
# I2P_HTTP_PROXY is non-empty, tell curl to use that as the proxy.
#
# The return value is the curl return value, or:
#     100: no or blank URL provided
#     101: invalid URL
#     102: URL is an onion site, but we can't connect to tor
#     103: non-tor URL has non-https scheme
#     104: prevented from dialing onion site
#     105: no I2P proxy provided
#     106: prevented from dialing I2P site
#
# Option -T will cause get to skip an onion site, silently, and 104 will be
# returned.
get ()
{
    local opt=
    local OPTIND
    local OPTARG
   
    local no_tor=n
    local no_i2p=n
    local url=
    local url_no_scheme=
    local scheme=
    local zone=
    local -i rc=0
    local -i tries=3
    local -i timeout=30
    local -a curl_cmd=(curl)

    while getopts "IT" opt
    do
        case "${opt}" in
        I) no_i2p=y ;;
        T) no_tor=y ;;
        *) ;;
        esac
    done
    shift $((OPTIND-1))

    if [[ -z "${1}" ]]
    then
        return 100
    fi
    url="${1}"

    # Get the canonical URL.
    url="$(canonicalize_url "${url}")"
    if [[ -z "${url}" ]]
    then
        return 101
    fi
    url_no_scheme="${url#*://}"

    # Extract the scheme. We only support HTTP or HTTPS. But maybe Libreddit
    # has a future on gopher...
    local scheme="${url%%://*}"
    case "${scheme}" in
    http|https) ;;
    *) return 101 ;;
    esac

    # Extract the zone.
    zone="$(<<<"${url}" sed -nE 's|^.+://.+\.([^\./]+)/?.*|\1|p')"

    # Special handling for Onion and I2P sites.
    #  - Onion/I2P sites can be either HTTPS or HTTP. But we want to enforce
    #    HTTPS on clearnet sites.
    #  - Increase curl max-time to 60 seconds.
    if [[ "${zone,,}" == "onion" ]]
    then
        # Don't bother if tor isn't running. But if both are available, 
        # make sure we warp curl with socks.
        if [[ "${no_tor}" == "y" ]]
        then
            return 104
        fi

        if ! can_tor
        then
            return 102
        fi

        timeout=60
        curl_cmd=(curl --proxy socks5h://localhost:9050)
    elif [[ "${zone,,}" == "i2p" ]]
    then
        if [[ "${no_i2p}" == "y" ]]
        then
            return 106
        fi

        if ! can_i2p
        then
            return 105
        fi

        timeout=60
        curl_cmd=(curl -x "${I2P_HTTP_PROXY}")
    elif [[ "${scheme}" != "https" ]]
    then
        return 103
    fi

    # Use a custom User-Agent if provided.
    if [[ -n "${USER_AGENT?}" ]]
    then
        curl_cmd=("${curl_cmd[@]}" -A "${USER_AGENT}")
    fi

    # Do the GET. Try up to the number of times specified in the tries variable.
    for (( i = tries; i > 0; i-- ))
    do
        "${curl_cmd[@]}" -m"${timeout}" -fs -- "${scheme}://${url_no_scheme}"
        rc=$?

        if [[ ${rc} -eq 0 ]]
        then
            return
        fi
    done

    return ${rc}
}

# create_instance_entry [-I] [-T] URL COUNTRY_CODE [CLOUDFLARE [DESCRIPTION]]
#
# Create JSON object for instance. To specify that the instance is behind
# Cloudflare, simply set the third argument to be true; any other value
# will be interpreted as false.
#
# A description can be specified in the fourth argument (which means that, if
# you want to specify description for a website for which Cloudflare is
# _disabled_, set the third argument to ""). If you pass description in,
# all quotes will need to be escaped, as this will go directly into a
# JSON string value. (The idea is that read_csv_row will do the appropriate
# processing of the rows, including escaping characters in the description
# column and we will then pass those values verbatim into this function.)
#
# Option -I/-T will cause get to skip an onion/i2p site, respectively, and 100
# will be returned.
create_instance_entry ()
{
    local cloudflare=n
    local res=
    local version=
    local json=
    local url_type="url"
    local -i rc=0
    local -a get_opts=()
    
    local opt=
    local OPTIND
    local OPTARG
    
    while getopts "IT" opt
    do
        case "${opt}" in
        I) get_opts+=("-I") ;;
        T) get_opts+=("-T") ;;
        *) ;;
        esac
    done
    shift $((OPTIND-1))
    
    local url="${1}"
    local country="${2}"
    local description="${4}"

    if [[ -z "${url}" || -z "${country}" ]]
    then
        return 1
    fi

    if [[ "${3}" == "true" ]]
    then
        cloudflare=y
    fi

    res="$(get "${get_opts[@]}" "${url}")"
    rc=$?

    if [[ ${rc} -ne 0 ]]
    then
        # 104-6 are returned if we prevented get from connecting to an
        # onion/i2p site. This requires us to return the special code 100.
        if [[ ${rc} -eq 104 || ${rc} -eq 105 || ${rc} -eq 106 ]]
        then
            return 100
        fi

        return 2
    fi

    if [[ -z "${res}" ]]
    then
        return 3
    fi

    # Scrape the version from the site.
    #
    # Future versions of Libreddit may advertise the version in a <meta> tag in
    # <head>, but it doesn't right now.
    version="$(<<<"${res}" sed -nE 's/.*\s+id="version">(v([0-9]+\.){2}[0-9]+).*$/\1/p')"
    if [[ -z "${version}" ]]
    then
        return 4
    fi

    # Find out if this is an onion/i2p website.
    # Yeah, this is a little lazy and we could do this a bit better.
    for zone in onion i2p
    do
        if [[ "${url,,}" =~ ^https?://[^/]+\.${zone}/?$ ]]
        then
            url_type="${zone}"
        fi
    done

    # Build JSON.
    json="{"
    json+="$(printf '"%s":"%s"' "${url_type}" "${url}")"
    json+=","
    json+="$(printf '"country":"%s"' "${country}")"
    json+=","
    json+="$(printf '"version":"%s"' "${version}")"

    if [[ "${cloudflare}" == "y" ]]
    then
        json+=","
        json+="\"cloudflare\":true"
    fi

    if [[ -n "${description}" ]]
    then
        # DANGER: If the description string isn't properly escaped, the JSON
        # will be malformed!
        json+=","
        json+="$(printf '"description":"%s"' "${description}")"
    fi
    json+="}"

    echo "${json}"
}

# helpdoc
#
# Print usage information to stdout.
helpdoc ()
{
    cat <<!
USAGE
    ${BASH_SOURCE[0]} [-I INPUT_JSON] [-T] [-e | -f] [-i INPUT_CSV] [-o OUTPUT_JSON]
    ${BASH_SOURCE[0]} -h

DESCRIPTION
    Generate a JSON of Libreddit instances, given a CSV file at INPUT_CSV
    listing those instances. If INPUT_CSV is not given, this script will
    read the CSV file from stdin.

    The INPUT_CSV file must be a file in CSV syntax of the form

        [url],[country code],[cloudflare enabled],[description]

    where all four parameters are required (though the description may be
    blank). Except for onion and I2P sites, all URLs MUST be HTTPS.

    OUTPUT_JSON will be overwritten if it exists. No confirmation will be
    requested from the user.

    By default:

    * This script will not attempt to connect to I2P instances. If you want
      this script to consider instances on the I2P network, you will need to
      provide an HTTP proxy in the environment variable I2P_HTTP_PROXY.
      This proxy typically listens at 127.0.0.1:4444.

    * This script will attempt to connect to instances in the CSV that are on
      Tor, provided that it can (it will check to see if Tor is running).
      If you want to disable connections to these onion sites, provide the
      -T option.

    * This script will return a non-zero status code when at least one instance
      could not be reached. If you want this script always to return 0 even
      when not all instances could be reached, provide the -e option (this
      script will still return a non-zero code if there was a problem
      constructing the final JSON object or if the file supplied to the -I
      option could not be read).

OPTIONS
    -I INPUT_JSON
        Import the list of Libreddit onion and I2P instances from the file
        INPUT_JSON. To use stdin, provide \`-I -\`. Implies -T, and further
        causes the script to ignore the value in I2P_HTTP_PROXY. Note that the
        argument provided to this option CANNOT be the same as the argument
        provided to -i. If the JSON could not be read, the script will exit with
        status code 1, even if -e is provided.

    -T
        Do not connect to Tor. Onion sites in INPUT_CSV will not be processed.
        Assuming no other failure, the script will still exit with status code
        0.

    -e
        Always exit with status code 0, even when at least one instance cannot
        be reached, except in the situations where (1) the file in INPUT_JSON
        (see \`-I\`) could not be processed; or (2) the JSON object could not
        be constructed. Cannot be used together with -f.

    -f
        Force the script to exit, with status code 1, upon the first failure to
        connect to an instance. Normally, the script will continue to build and
        output the JSON even when one or more of the instances could not be
        reached, though the exit code will be non-zero. Cannot be used together
        with -e.

    -i INPUT_CSV
        Use INPUT_CSV as the input file. To read from stdin (the default
        behavior), either omit this option or provide \`-i -\`. Note that the
        argument provided to this option CANNOT be the same as the argument
        provided to -I.

    -o OUTPUT_JSON
        Write the results to OUTPUT_JSON. Any existing file will be
        overwritten. To write to stdout (the default behavior), either omit
        this option or provide \`-o -\`.

ENVIRONMENT

    USER_AGENT
        Sets the User-Agent that curl will use when making the GET to each
        website. By default, this script will tell curl to set its User-Agent
        string to "${DEFAULT_USER_AGENT}".

    I2P_HTTP_PROXY
        HTTP proxy for connecting to the I2P network. This is required in
        order to connect to instances on I2P. If -I is provided, the value in
        this variable is ignored.
!
}

# main
#
# Main function.
main ()
{
    local opt=
    local OPTIND
    local OPTARG

    local nofailrc=n
    local failfast=n
    local do_tor=y
    local do_i2p=y
    local -a get_opts=()
    local -a missing_deps=()
    local import_nonwww_from_file=
    local input_file=/dev/stdin
    local output_file=/dev/stdout
    local -a instance_entries=()
    local -a imported_nonwww=()
    local instance_entry=
    local -i rc=0
    local json_corrupted=n

    while getopts ":I:Tefhi:o:" opt
    do
        case "${opt}" in
        I) import_nonwww_from_file="${OPTARG}" ;;
        T) do_tor=n ;;
        e) nofailrc=y ;;
        f) failfast=y ;;
        h) helpdoc ; exit ;;
        i)
            input_file="${OPTARG}"
            if [[ -z "${input_file}" ]]
            then
                echo >&2 "-i: Please specify a file."
            fi

            if [[ "${input_file}" == '-' ]]
            then
                input_file=/dev/stdin
            fi
            ;;
        o)
            output_file="${OPTARG}"
            if [[ -z "${output_file}" ]]
            then
                echo >&2 "-o: Please specify a file."
            fi

            if [[ "${output_file}" == '-' ]]
            then
                output_file=/dev/stdout
            fi
            ;;
        \?)
            echo >&2 "-${OPTARG}: invalid option"
            helpdoc
            exit 255
            ;;
        esac
    done

    # -e and -f cannot be used together.
    if [[ "${nofailrc}" == "y" && "${failfast}" == "y" ]]
    then
        echo >&2 "-e and -f canont be used together."
        helpdoc
        exit 255
    fi

    # Make sure we have necessary dependencies before moving forward.
    # shellcheck disable=SC2207
    IFS=$'\n' missing_deps=($(check_dependencies))

    if [[ ${#missing_deps} -ne 0 ]]
    then
        {
            echo "Dependencies are missing. Please install them and then try running the script again."
            echo
            echo "Missing dependencies:"

            for dep in "${missing_deps[@]}"
            do
                echo -e "\t${dep}"
            done
        } >&2
        return 1
    fi

    # Special handling for -I.
    if [[ -n "${import_nonwww_from_file}" ]]
    then
        # Abort if -I and -i point to the same file.
        if [[ "${import_nonwww_from_file}" == "${input_file}" ]]
        then
            echo >&2 "-I and -i cannot point to the same file."
            echo >&2 "For more information, run: ${BASH_SOURCE[0]} -h"
            return 1
        fi
        
        # Set do_tor <- n so that we don't attempt to make tor connections.
        do_tor=n

        # Do the same for i2p.
        do_i2p=n

        # Attempt to read in onion instances.
        # shellcheck disable=SC2207
        # (a mapfile would not ideal here since a pipe is required, inducing a
        # subshell, meaning nothing will actually get added to
        # imported_nonwww)
        IFS=$'\n' imported_nonwww=($(jq -Mcer '.instances[] | select(.onion or .i2p)' "${import_nonwww_from_file}"))
        rc=$?

        if [[ ${rc} -ne 0 ]]
        then
            echo >&2 "Failed to read onion instances from existing JSON file."
            return 1
        fi
    fi

    # Check to see if we have tor. If we don't, then we will have to import
    # the existing tor instances from the JSON.
    # TODO: For I2P, we will likely have to do something similar.
    if [[ "${do_tor}" == "n" ]] || ! can_tor
    then
        if [[ "${do_tor}" == "y" ]]
        then
            echo >&2 "WARNING: The tor service is not running. Onion sites will not be processed."
        fi
        do_tor="n"
        get_opts+=("-T")
    fi

    # Don't attempt I2P connections if no proxy was given.
    if ! can_i2p
    then
        do_i2p="n"
    fi

    if [[ "${do_i2p}" == "n" ]]
    then
        get_opts+=("-I")
    fi

    if [[ "${input_file}" != "/dev/stdin" ]]
    then
        if [[ ! -e "${input_file}" ]]
        then
            echo >&2 "${input_file}: No such file or directory"
            return 1
        fi

        if [[ -d "${input_file}" ]]
        then
            echo >&2 "${input_file}: Is a directory"
            return 1
        fi
    fi
   
    # Read in the CSV.
    if [[ "${input_file}" == "/dev/stdin" ]]
    then
        echo >&2 "Reading from stdin..."
    fi
    local -a rows=()
    <"${input_file}" mapfile rows
    rc=0

    if [[ ${rc} -ne 0 ]]
    then
        return ${rc}
    fi

    # Process the CSV, row by row.
    local -a values=()
    local -a failed=()
    local l=1
    local url=
    for row in "${rows[@]}"
    do
        # shellcheck disable=SC2207
        IFS=$'\n' values=($(read_csv_row "${row}"))
        rc=$?

        if [[ ${rc} -ne 0 || ${#values[@]} -lt 3 || ${#values[@]} -gt 4 ]]
        then
            echo >&2 "${l}: failed to parse row"
            echo >&2 "Script will now terminate."
            return 2
        fi
       
        # Print friendly message to log while processing row.
        url="${values[0]}"
        echo -n >&2 "${url}: "
        
        instance_entry="$(IFS=$'\n' create_instance_entry "${get_opts[@]}" "${values[@]}")"
        rc=$?

        if [[ ${rc} -eq 0 ]]
        then
            IFS=$'\n' instance_entries+=("${instance_entry}")
            echo "OK"
        elif [[ ${rc} -eq 100 ]]
        then
            # rc=100 means the onion site is skipped because we told
            # create_instance_entry to skip the onion site.
            echo "SKIPPED"
        else
            echo "FAILED"
            
            if [[ "${failfast}" == "y" ]]
            then
                return 1
            fi

            failed+=("${url}")
        fi >&2

        (( l++ ))
        rc=0
    done

    # Assemble everything into JSON.
    # TODO: see if this can be done in one jq call, without having
    # to pass the list to jq --slurp and then everything to jq.
    printf '{"updated":"%s","instances":%s}' "${TODAY}" "$(IFS=$'\n'
        for instance in "${instance_entries[@]}" "${imported_nonwww[@]}"
        do
            echo "${instance}"
        done | jq -Mcers .
    )" | jq -Mer . >"${output_file}"
    rc=$?

    if [[ ${rc} -ne 0 ]]
    then
        echo >&2 "There was a problem processing the JSON. The output file may be corrupted."
        json_corrupted=y
    fi

    if [[ ${#failed[@]} -gt 0 ]]
    then
        {
            echo "The following instances could not be reached:"
            for failed_url in "${failed[@]}"
            do
                echo -e "\t${failed_url}"
            done
        } >&2

        if [[ "${nofailrc}" == "y" ]]
        then
            # Special case when user provides -e: exit with 0, except if the
            # JSON is corrupted.
            if [[ "${json_corrupted}" == "n" ]]
            then
                return 0
            fi
        else
            # Normal case: return non-zero code on this failure.
            return 1
        fi
    fi

    # This will be non-zero if the JSON is corrupted.
    return ${rc}
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
    main "${@}"
    exit
fi
