#!/usr/bin/env python3

"""
This script generates a markdown table containing the list of Libreddit
instances from an instances JSON file. It is assumed that the input instances
JSON file follows the schema as instances-schema.json.

This script requires python3 of at least version 3.5.

Almost all of this script is licensed under the GNU General Public License,
version 3.

A portion of this script, specifically the function `flag()`, is adapted from
Django Countries (https://github.com/SmileyChris/django-countries), licensed
under the MIT License. Pursuant to the copyright notice requirement of that
license, the full contents of the license agreement as of Nov 5, 2022, are
reproduced below.

    Copyright (c) 2010 Chris Beaven and contributors

    Permission is hereby granted, free of charge, to any person
    obtaining a copy of this software and associated documentation
    files (the "Software"), to deal in the Software without
    restriction, including without limitation the rights to use,
    copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the
    Software is furnished to do so, subject to the following
    conditions:

    The above copyright notice and this permission notice shall be
    included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
    EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
    OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
    NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
    HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
    WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
    FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
    OTHER DEALINGS IN THE SOFTWARE.
"""

import argparse
import json
import os
import sys

# This script requires at least Python 3.5.
if sys.version_info[1] < 5:
    raise SystemError("Your python3 ({}.{}.{}) is too old. You need at least 3.5.".format(sys.version_info[0], sys.version_info[1], sys.version_info[2]))

def flag(code: str) -> str:
    """
    Generate a regional indicator symbol from an ISO 3166-1 alpha-2 country
    code.

    This code is adapted from Django Countries:
        https://github.com/SmileyChris/django-countries/blob/732030e5c912875927fcc012e0bb2e392ae10a0b/django_countries/fields.py#L143
    which at the time of adaptation was licensed under MIT:
        https://github.com/SmileyChris/django-countries/blob/732030e5c912875927fcc012e0bb2e392ae10a0b/LICENSE
    which permits modification and distribution of code.
    """

    OFFSET = 127397

    if not code:
        return ""

    points = [ord(x) + OFFSET for x in code.upper()]
    return chr(points[0]) + chr(points[1])

def main(args: list) -> int:
    """
    Main program function. Does everything the script is supposed to do.
    """

    # Set up options and parse arguments.
    parser = argparse.ArgumentParser(description="""
Generate a markdown table of the Libreddit instances in the instances.JSON
file. By default, this will read the file 'instances.json' in the current
working directory, and will write to 'instances.md' in that same directory.
WARNING: This script will overwrite the output file if it exists.
""")
    parser.add_argument("INPUT_FILE", default="instances.json", nargs="?",
            help="location of instances JSON")
    parser.add_argument("-o", "--output", dest="OUTPUT_FILE",
            default="instances.md", help="where to write the markdown table; \
                if a file exists at this path, it will be overwritten")

    parsed_args = parser.parse_args(args[1:])

    try:
        with open(parsed_args.INPUT_FILE) as f:
            instances = json.load(f)
    except Exception as e:
        sys.stderr.write("Error opening '{}' for reading:\n".format(parsed_args.INPUT_FILE))
        sys.stderr.write("\t" + e.__str__() + "\n")
        return 1

    table_preamble = "|URL|Network|Version|Reddit|Location|Behind Cloudflare?|Comment|\n|-|-|-|-|-|-|-|\n"
    table_rows = []
    for instance in instances["instances"]:
        url = ""
        network = ""
        version = ""
        country = "(n/a)"
        cloudflare = False
        description = ""

        if "url" in instance:
            url = instance["url"] 
            network = "WWW"
        elif "onion" in instance:
            url = instance["onion"]
            network = "Tor"
        elif "i2p" in instance:
            url = instance["i2p"]
            network = "I2P"
        else:
            # Couldn't determine network, so skip instance.
            continue

        # Version is a required parameter. If this is not in the JSON, skip
        # this instance.
        if "version" not in instance:
            sys.stderr.write("Skipping '{}': no version recorded".format(url))
            continue
        else:
            version = instance["version"]

        # What the instance reported about Reddit when it was checked, if it
        # reports that at all.
        reddit = {"ok": "\u2705", "scraped": "\u26a0\ufe0f scraped", "blocked": "\u274c blocked"}.get(instance.get("reddit"), "")

        if "country" in instance:
            country = instance["country"]

        if "cloudflare" in instance and instance["cloudflare"]:
            cloudflare = True

        if "description" in instance:
            description = instance["description"]

        location = ""
        try:
            fl = flag(country)
            location = fl + " " + country
        except Exception:
            location = country

        table_rows.append("|{0}|{1}|{2}|{3}|{4}|{5}|{6}|\n".format(
            url,
            network,
            version,
            reddit,
            location,
            "\u2705" if cloudflare else "",
            description
        ))

    if parsed_args.OUTPUT_FILE == "-":
        out = sys.stdout
    else:
        try:
            out = open(parsed_args.OUTPUT_FILE, "w" if os.path.exists(parsed_args.OUTPUT_FILE) else "x")
        except Exception as e:
            sys.stderr.write("Error opening '{}' for writing:\n".format(parsed_args.OUTPUT_FILE))
            sys.stderr.write("\t" + e.__str__() + "\n")
            return 1

    out.write(table_preamble)
    for row in table_rows:
        out.write(row)
    out.close()

    return 0

if __name__ == "__main__":
    rc = main(sys.argv)
    sys.exit(rc)
