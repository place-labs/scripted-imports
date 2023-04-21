# Example Import Scripts

Modify for importing your specific data. Recommend:

1. writing scripts that can be executed multiple times
2. use a source of truth like a published Google Sheets (publish in TSV format for best results)
3. use API keys for instance access

## Usage

1. `shards build`
2. `./bin/import_bookings`
3. `./bin/import_desks`

## Desk Command line switches

* `-f ./data.tsv` if you have the data locally
* `-u https://path_to_TSV` if you've published a google sheet
* `-d https://placeos.domain` the placeos instance
* `-k abs1234xfndsx` the placeos api key

i.e.

```
./bin/import_desks -d "https://placeos.domain" -k "c3c1ebeb60d94dcc96caf5fae12"
```
