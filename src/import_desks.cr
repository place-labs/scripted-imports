require "option_parser"
require "placeos"
require "csv"

# Defaults
tsv_uri = "https://docs.google.com/spreadsheets/d/e/2PACFM/pub?gid=917433&single=true&output=tsv"
tsv_file = ""

api_key = "4abedae4e97dced85219feb2f0f1"
place_domain = "http://my.placeos.domain"

metadata_name = "desks"

# Command line options
OptionParser.parse do |parser|
  parser.banner = "Usage: #{PROGRAM_NAME} [arguments]"

  parser.on("-f PATH", "--file=PATH", "the file to use for the import") do |file|
    tsv_file = file
  end

  parser.on("-u URI", "--uri=URI", "google document URI for import") do |uri|
    tsv_uri = uri
  end

  parser.on("-d DOMAIN", "--domain=DOMAIN", "the domain of the PlaceOS server") do |dom|
    place_domain = dom
  end

  parser.on("-k API_KEY", "--api_key=API_KEY", "placeos API key for access") do |k|
    api_key = k
  end

  parser.on("-m METANAME", "--meta=METANAME", "metadata key name") do |m|
    metadata_name = m
  end

  parser.on("-h", "--help", "Show this help") do
    puts parser
    exit 0
  end
end

# Extract the TSV details
tsv = if tsv_file.blank?
        puts "Loading URI: #{tsv_uri}"
        response = HTTP::Client.get tsv_uri
        if response.status.temporary_redirect?
          response = HTTP::Client.get(response.headers["Location"])
        end
        raise "failed to connect to" unless response.success?

        CSV.new(response.body, headers: true, strip: true, separator: '\t')
      else
        puts "Loading file: #{tsv_file}"
        CSV.new(File.new(tsv_file), headers: true, strip: true, separator: '\t')
      end

# Ignore the headers
tsv.next

# Prepare the data structures
alias Desk = NamedTuple(
  bookable: Bool,
  group: String?,
  name: String,
  id: String,
)

zones = Hash(String, Array(Desk)).new do |h, k|
  h[k] = [] of Desk
end

# Extract the data
BOOKABLE = {"true", "yes"}
row_count = 0
puts "Parsing data..."
tsv.each do |row|
  zone_id = row["zone"]
  bookable = row["bookable"].downcase
  group = row["group"].downcase
  desk_id = row["id"]
  desk_name = row["name"]

  group = nil if group.starts_with?("not") || group.blank?
  bookable = BOOKABLE.includes?(bookable)

  row_count += 1

  zones[zone_id] << {
    bookable: bookable,
    group:    group,
    name:     desk_name,
    id:       desk_id,
  }
end

# Configure the PlaceOS client
client = PlaceOS::Client.new(place_domain,
  x_api_key: api_key,
  insecure: true, # if using a self signed certificate
)

puts "Extracted #{row_count} desks, uploading..."
errors = 0

zones.each do |zone_id, metadata|
  begin
    client.metadata.update(zone_id, metadata_name, metadata, "")
  rescue error
    errors += 1
    if error.message =~ /not found/i
      puts "Failed to find #{zone_id}"
    else
      raise error
    end
  end
end

if errors == 0
  puts "success"
else
  puts "#{errors} errors"
end
