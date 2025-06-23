require "http"
require "json"
require "uri"

org = "zone-EFejbY"
campus = "zone-EFemfu"
building = "zone-Ih3IS"
api_key = "ed34d0fca693355292401f6dac2.QoMrI3E9lRAbA_JxZTBthkOEu1GDFPxAu8BU"
domain = "domain.au"
desk_list = ARGV[0]? || "./red-desks.txt"

puts "parsing: #{desk_list}"

# ==========================
# find all the desk mappings
# ==========================
# desk id => assignment email
puts "Loading desk ids..."
desk_ids = Set(String).new

response = HTTP::Client.get("https://#{domain}/api/engine/v2/metadata/#{building}/children?include_parent=false&name=desks", headers: HTTP::Headers{
  "X-API-Key" => api_key,
  "Host"      => domain,
})
raise "unable to fetch building zones" unless response.success?

record DeskDetails, desk_id : String, desk_name : String

# email => [] of desks
assigned_to = Hash(String, Array(DeskDetails)).new do |hash, key|
  hash[key] = [] of DeskDetails
end

# desk_name => DeskDetails
# desk_id => DeskDetails
lookup_desk = {} of String => DeskDetails

json = JSON.parse(response.body)
json.as_a.each do |level|
  level_zone = level["zone"]["id"].as_s

  if desks = level["metadata"]["desks"]?
    desks["details"].as_a.each do |desk|
      desk_id = desk["id"].as_s
      desk_name = desk["name"]?.try(&.as_s?) || desk_id
      details = DeskDetails.new(desk_id, desk_name)

      lookup_desk[desk_id] = details
      lookup_desk[desk_name] = details
    end
  end
end


# ==============================================
# Load in the list of desks we want QR codes for
# ==============================================


puts "Reading file #{desk_list}..."
desks = File.read(desk_list)
desks = desks.split("\n").compact_map(&.strip.presence)
desks = desks.compact_map do |desk|
  check = "desk-#{desk}"
  if details = lookup_desk[check]? || lookup_desk[desk]?
    details.desk_id
  else
    puts "couldn't find desk with id: #{check}"
  end
end

# ===================================
# Generate the short URLs
# ===================================

puts "Creating short URLs..."
desk_urls = {} of String => String
uris = desks.each do |desk_id|
  continue = URI.encode_path_segment("/workplace/#/book/code?asset_id=#{desk_id}&building_id=#{building}&region_id=#{campus}")
  desk_urls[desk_id] = "https://redirector.au/redirect/?continue=#{continue}"
end

puts "desk id,long URL,short URL"
desk_urls.each do |desk, url|
  print "#{desk},#{url},"
  payload = {
    name:    "Desk Booking: #{desk}",
    uri:     url,
    enabled: true,
  }.to_json
  request = URI.new("https", domain, 443, "/api/engine/v2/short_url")
  response = HTTP::Client.post(request, headers: HTTP::Headers{
    "X-API-Key" => api_key,
    # "Host" => domain,
  }, body: payload)
  raise "error #{response.status_code}, #{response.body}" unless response.success?
  short_url = JSON.parse(response.body).as_h

  id = short_url["id"].as_s.split("-", 2)[1]
  puts "https://#{domain}/r/#{id}"
end

puts "done!"
