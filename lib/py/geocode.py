"""Look up places and current temperature through Open-Meteo (no API key).

geocode.py search NAME     -> lines: label<TAB>lat<TAB>lon
geocode.py current LAT LON -> current temperature in degrees C

HOMEWAN_FIXTURES, when set, supplies geocode.json and current.json.
Exit status 2 when the service cannot be reached.
"""
import json
import os
import sys
import urllib.parse
import urllib.request


def fetch(url, fixture):
    fx = os.environ.get("HOMEWAN_FIXTURES")
    if os.environ.get("HOMEWAN_TEST") == "1" and fx:
        with open(os.path.join(fx, fixture)) as f:
            return json.load(f)
    with urllib.request.urlopen(url, timeout=15) as r:
        return json.load(r)


def main():
    try:
        if sys.argv[1] == "search":
            q = urllib.parse.urlencode({"name": sys.argv[2], "count": 8, "language": "en", "format": "json"})
            data = fetch(f"https://geocoding-api.open-meteo.com/v1/search?{q}", "geocode.json")
            for r in data.get("results", []) or []:
                label = ", ".join(x for x in (r.get("name"), r.get("admin1"), r.get("country_code")) if x)
                print(f'{label}\t{r["latitude"]:.4f}\t{r["longitude"]:.4f}')
        elif sys.argv[1] == "current":
            q = urllib.parse.urlencode({"latitude": sys.argv[2], "longitude": sys.argv[3], "current": "temperature_2m"})
            data = fetch(f"https://api.open-meteo.com/v1/forecast?{q}", "current.json")
            print(data["current"]["temperature_2m"])
    except (OSError, ValueError, KeyError) as e:
        print(f"lookup failed: {e}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
