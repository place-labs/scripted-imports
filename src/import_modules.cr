require "option_parser"
require "placeos"
require "set"
require "csv"

ORG = "Charles Darwin University"
ORG_REGEX = /#{ORG}/i
TIMEZONE = "Australia/Darwin"

module Extract
  extend self

  LOC_REGEX = /(?<building>\D+)\s*(?<level>\d+)\.(?<room>\d+)/

  # from "location" column
  def location(text : String)
    if match = LOC_REGEX.match(text)
      # Access named captures
      building = match["building"]
      level = match["level"].to_i
      room = match["room"].to_i

      return {building, level, room}
    end
    {nil, nil, nil}
  end

  # from "location", "description" and "mac" columns
  def description(location : String, description : String, mac : String?)
    desc = description.sub(location, "").strip
    desc = "#{desc}\n\nmac: #{mac}" if mac.presence
    desc
  end
end

# defaults if you don't want to use command line options
api_key = "heRxMB3c"
place_domain = "https://placeos-dev.cdu.edu.au"
csv_file = ""

# Command line options
OptionParser.parse do |parser|
  parser.banner = "Usage: #{PROGRAM_NAME} [arguments]"

  parser.on("-d DOMAIN", "--domain=DOMAIN", "the domain of the PlaceOS server") do |dom|
    place_domain = dom
  end

  parser.on("-k API_KEY", "--api_key=API_KEY", "placeos API key for access") do |key|
    api_key = key
  end

  parser.on("-i CSV", "--import=CSV", "csv file to import") do |file|
    csv_file = file
  end

  parser.on("-h", "--help", "Show this help") do
    puts parser
    exit 0
  end
end

# ======================================
# Grab any existing building information
# ======================================

# Configure the PlaceOS client
client = PlaceOS::Client.new(place_domain,
  x_api_key: api_key,
  insecure: true, # if using a self signed certificate
)

puts "============================"
puts "inspecting existing zones..."

# Ensure organisation exists
org_zones = client.zones.search(limit: 1000, tags: "org")
org_zone = org_zones.find { |zone| zone.name.match(ORG_REGEX) }

if org_zone
  puts " > found org zone: #{org_zone.name} (#{org_zone.id})"
else
  org_zone = client.zones.create(ORG, tags: ["org"])
  puts " + created org zone: #{org_zone.name} (#{org_zone.id})"
end

# Grab existing level and building zones
building_zones = client.zones.search(limit: 1000, tags: "building", parent_id: org_zone.id)
puts " > found #{building_zones.size} building zones"

level_zones = client.zones.search(limit: 1000, tags: "level")
puts " > found #{level_zones.size} level zones"

# =======================
# Extract the CSV data
# =======================
if !csv_file.presence || !File.exists?(csv_file)
  puts "could not find CSV file: #{csv_file}"
  exit 1
end

puts "============================"
puts "Loading file: #{csv_file}"
# remove any byte order marks
file_contents = File.read(csv_file).sub("\uFEFF", "")
csv = CSV.new(file_contents, headers: true, strip: true, separator: ',')

# Ignore the headers
csv.next

puts "============================"
puts "Parsing CSV data..."
record ModuleEntry, ip : String, device : String, description : String, building : String, level : Int32, room : Int32
entries = [] of ModuleEntry
building_entries = Set(String).new
level_entries = Set(Tuple(String, Int32)).new
room_entries = Set(Tuple(String, Int32, Int32)).new
csv.each do |row|
  # extract column data
  ip = row["ip address"]
  description = row["description"]
  mac = row["mac"]
  device = row["device"]
  location = row["location"]

  building, level, room = Extract.location(location)
  unless building && level && room
    puts " > skipping row with no location"
    next
  end
  building = building.downcase
  description = Extract.description(location, description, mac)

  entries << ModuleEntry.new(ip, device, description, building, level, room)
  building_entries << building
  level_entries << {building, level}
  room_entries << {building, level, room}
end

puts " > found #{entries.size} valid entries"

# ================================
# Create missing systems and zones
# ================================
puts "==================================="
puts "Locating required systems and zones"
alias Zone = PlaceOS::Client::API::Models::Zone
alias CtrlSystem = PlaceOS::Client::API::Models::System

BUILDING_MAPPINGS = {
  "ecp" => {"Education & Community Precinct", "ECP"}
}

buildings = {} of String => Zone
levels = {} of Tuple(String, Int32) => Zone
existing_rooms = Hash(Tuple(String, Int32), Array(CtrlSystem)).new { |hash, key| hash[key] = [] of CtrlSystem }
rooms = {} of Tuple(String, Int32, Int32) => CtrlSystem

zones_added = 0
systems_added = 0

building_entries.each do |building|
  puts " > looking for #{building}"
  mapping = BUILDING_MAPPINGS[building]?
  unless mapping
    puts "   ! no mapping found, unexpected building code"
    exit 2
  end

  zone = building_zones.find do |b_zone|
    b_zone.name == mapping[0] || b_zone.display_name == mapping[1]
  end

  if zone.nil?
    puts "   building not found, creating zone"
    zone = client.zones.create(
      name: mapping[0],
      display_name: mapping[1],
      tags: ["building"],
      parent_id: org_zone.id
    )
    zones_added += 1
  end
  buildings[building] = zone
end

level_entries.each do |(building_name, level_idx)|
  puts " > looking for level #{building_name} L#{level_idx}"
  building_zone = buildings[building_name]

  level_name = "#{building_zone.display_name} Level #{level_idx}"
  level_display = "#{building_zone.display_name}L#{level_idx}"

  zone = level_zones.find do |l_zone|
    l_zone.name == level_name || l_zone.display_name == level_display
  end

  if zone.nil?
    puts "   level not found, creating zone"
    zone = client.zones.create(
      name: level_name,
      display_name: level_display,
      tags: ["level"],
      parent_id: building_zone.id
    )
    zones_added += 1
  end
  levels[{building_name, level_idx}] = zone
  existing_rooms[{building_name, level_idx}] = client.systems.search(zone_id: zone.id)
end

room_entries.each do |(building_name, level_idx, room_idx)|
  room_id = "#{level_idx}.#{room_idx.to_s.rjust(2, '0')}"
  puts " > looking for room #{building_name} #{room_id}"

  building_zone = buildings[building_name]
  level_lookup = {building_name, level_idx}
  level_zone = levels[level_lookup]
  existing = existing_rooms[level_lookup]

  room_name = "#{building_zone.display_name} #{room_id}"
  room_display = room_id

  system = existing.find do |candidate_sys|
    if display_name = candidate_sys.display_name
      candidate_sys.name.includes?(room_id) || display_name.includes?(room_id)
    else
      candidate_sys.name.includes?(room_id)
    end
  end

  if system.nil?
    puts "   room not found, creating room"
    system = client.systems.create(
      name: room_name,
      display_name: room_display,
      zones: [org_zone.id, building_zone.id, level_zone.id],
      bookable: true,
      timezone: TIMEZONE
    )
    system = client.systems.update(system.id, system.version, support_url: "https://placeos.cdu.edu.au/control/#/tabbed/#{system.id}")
    systems_added += 1
  end
  rooms[{building_name, level_idx, room_idx}] = system
end

# ================================
# Locate drivers
# ================================
puts "========================="
puts "Locating required drivers"

DRIVER_MAPPINGS = {
  /crestron\s+cen/i => "Crestron Occupancy Sensor",
  /display\s+.*crestron\s+dm/i => "Crestron NVX Receiver",
  /crestron\s+dm/i => "Crestron NVX Transmitter",
  # don't create a driver for the dante ip's
  /sys\s+core(?!.*dante)/i => "QSC Audio DSP",
  /aver/i => "Aver 520 Pro Camera",
  /kramer\s+rc/i => "Kramer RC-308 Key Pad",
  # /kramer\s+kt/i => "touch panel",
  # /LabGruppen/i => "?",
  /samsung\s+lh/i => "Samsung Simplified Control Set",
}

LOGIC_DRIVERS = [
  "Meeting room logic",
  "Crestron Virtual Switcher",
  "PlaceOS Room Events",
  "KNX Lighting",
]

alias Driver = PlaceOS::Client::API::Models::Driver

available_drivers = client.drivers.search(limit: 1000)
driver_lookup = {} of String => Driver

# ensure all required drivers have been added to the cluster
(DRIVER_MAPPINGS.values + LOGIC_DRIVERS).each do |name|
  puts " > looking for driver: #{name}"
  if driver = available_drivers.find { |check| check.name == name }
    driver_lookup[name] = driver
  else
    puts "   not found! Please add to cluster"
    exit 3
  end
end

# ================================
# Add modules to systems
# ================================
puts "========================"
puts "Adding modules to system"

alias Module = PlaceOS::Client::API::Models::Module

# system id => array(modules)
existing_modules = Hash(String, Array(Module)).new { |hash, sys_id| hash[sys_id] = client.modules.search(limit: 1000, control_system_id: sys_id) }
mod_checked = 0
mod_no_match = 0
mod_added = 0

entries.each do |entry|
  puts " > checking #{entry.ip} in #{entry.building} #{entry.level}.#{entry.room.to_s.rjust(2, '0')}"
  mod_checked += 1

  # find driver
  desc = entry.description
  key = DRIVER_MAPPINGS.keys.find { |key| key =~ desc }
  if key.nil?
    puts "   no matching driver, skipping #{desc}"
    mod_no_match += 1
    next
  end
  driver = driver_lookup[DRIVER_MAPPINGS[key]]
  system = rooms[{entry.building, entry.level, entry.room}]

  # check if module already exists
  ip_uri = ""
  port = driver.default_port

  config = case driver.role
  when .ssh?, .device?
    ip_uri = entry.ip
  when .service?, .websocket?
    fallback = driver.role.websocket? ? "ws://test.com" : "http://test.com"
    ip_uri = URI.parse(driver.default_uri || fallback)
    ip_uri.host = entry.ip
  else
    puts "   invalid driver role: #{driver.role}"
    exit 4
  end

  modules = existing_modules[system.id]
  mod = modules.find do |e_mod|
    e_mod.driver_id == driver.id && (e_mod.uri == ip_uri || e_mod.ip == ip_uri)
  end

  next if mod

  begin
    puts "   creating module"
    mod = if ip_uri.is_a?(URI)
      client.modules.create(driver.id, uri: ip_uri.to_s, notes: desc)
    else
      client.modules.create(driver.id, ip: ip_uri.to_s, port: port, notes: desc)
    end
    modules << mod
    mod_added += 1

    system = client.systems.update(system.id, system.version, modules: modules.map(&.id))
    rooms[{entry.building, entry.level, entry.room}] = system
  rescue error
    puts "Failed to create: #{driver.name} #{ip_uri} #{port} #{desc}"
    raise error
  end
end

# ================================
# Add logic to systems
# ================================
puts "=============================="
puts "Adding logic modules to systems"

rooms.each do |(building_name, level_idx, room_idx), system|
  room_id = "#{level_idx}.#{room_idx.to_s.rjust(2, '0')}"
  modules = existing_modules[system.id]

  LOGIC_DRIVERS.each do |name|
    puts " > checking #{name} in #{building_name} #{room_id}"
    driver = driver_lookup[name]
    mod = modules.find { |e_mod| e_mod.driver_id == driver.id }

    next if mod

    puts "   creating module"

    # logic modules automatically added to systems
    client.modules.create(driver.id, control_system_id: system.id)
  end
end

puts "=============================="
puts "COMPLETE"
puts "=============================="

puts "zones created: #{zones_added}"
puts "systems created: #{systems_added}"
puts "modules created: #{mod_added}"
puts "modules skipped: #{mod_no_match} (unknown driver)"
puts "modules checked: #{mod_checked}"
