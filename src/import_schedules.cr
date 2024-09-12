require "option_parser"
require "placeos"
require "uuid"
require "set"
require "csv"

ORG       = "Charles Darwin University"
ORG_REGEX = /#{ORG}/i
TIMEZONE  = "Australia/Darwin"
BUILDING  = "Darwin City"

module Extract
  extend self

  LOC_REGEX = /(?<level>\d+)\.(?<room>\d+)/

  # from "location" column
  def location(text : String)
    if match = LOC_REGEX.match(text)
      # Access named captures
      level = match["level"].to_i
      room = match["room"].to_i

      return {level, room}
    end
    {nil, nil}
  end
end

# defaults if you don't want to use command line options
api_key = "MB3c"
place_domain = "https://placeos-dev.cdu.edu.au"
csv_file = "resource_booker_ids.csv"

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
building_zone = building_zones.find(&.name.starts_with?(BUILDING))

unless building_zone
  puts "Failed to find matching building zone"
  exit 1
end

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
# remove any UTF8 byte order marks
file_contents = File.read(csv_file).sub("\uFEFF", "")
csv = CSV.new(file_contents, headers: true, strip: true, separator: ',')

# Ignore the headers
csv.next

puts "============================"
puts "Parsing CSV data..."
record RoomEntry, description : String, email : String, level : Int32, room : Int32
entries = [] of RoomEntry
level_entries = Set(Int32).new
room_entries = Set(Tuple(Int32, Int32)).new
room_emails = {} of Tuple(Int32, Int32) => String

csv.each do |row|
  # extract column data
  email = row["Resource ID"]
  description = row["Room Name"]
  location = row["Room Number"]

  level, room = Extract.location(location)
  unless level && room
    puts " > skipping row with no location"
    next
  end

  if !email.includes?("@")
    email = "#{email}@cdu.edu.au"
  end

  entries << RoomEntry.new(description, email, level, room)
  level_entries << level
  room_entries << {level, room}
  room_emails[{level, room}] = email
end

puts " > found #{entries.size} valid entries"

# ================================
# Create missing systems and zones
# ================================
puts "==================================="
puts "Locating required systems and zones"
alias Zone = PlaceOS::Client::API::Models::Zone
alias CtrlSystem = PlaceOS::Client::API::Models::System

levels = {} of Int32 => Zone
existing_rooms = Hash(Int32, Array(CtrlSystem)).new { |hash, key| hash[key] = [] of CtrlSystem }
rooms = {} of Tuple(Int32, Int32) => CtrlSystem

zones_added = 0
systems_added = 0

level_entries.each do |level_idx|
  puts " > looking for level #{building_zone.name} L#{level_idx}"

  level_name = "#{building_zone.display_name} Level #{level_idx}"
  level_display = "#{building_zone.display_name} L#{level_idx}"

  zone = level_zones.find do |l_zone|
    l_zone.name.downcase.starts_with?(level_name.downcase) || l_zone.display_name.try(&.downcase) == level_display.downcase
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
  levels[level_idx] = zone
  existing_rooms[level_idx] = client.systems.search(zone_id: zone.id)
end

room_entries.each do |(level_idx, room_idx)|
  room_id = "#{level_idx}.#{room_idx.to_s.rjust(2, '0')}"
  puts " > looking for room #{building_zone.name} #{room_id}"

  level_zone = levels[level_idx]
  existing = existing_rooms[level_idx]

  room_name = "#{building_zone.display_name} #{room_id}"
  room_display = room_id

  system = existing.find do |candidate_sys|
    if display_name = candidate_sys.display_name
      candidate_sys.name.includes?(room_id) || display_name.includes?(room_id)
    else
      candidate_sys.name.includes?(room_id)
    end
  end

  email = room_emails[{level_idx, room_idx}]

  if system.nil?
    puts "   room not found, creating room"
    system = client.systems.create(
      name: room_name,
      display_name: room_display,
      zones: [org_zone.id, building_zone.id, level_zone.id],
      bookable: true,
      timezone: TIMEZONE,
      email: email
    )
    # system = client.systems.update(system.id, system.version, support_url: "https://placeos.cdu.edu.au/control/#/tabbed/#{system.id}")
    systems_added += 1
  elsif !system.name.starts_with?(room_name) || system.email != email
    puts "   updating room email: #{room_name} => #{email}"
    if system.name.starts_with?(room_name)
      # don't change name if not required
      room_name = system.name
      room_display = system.display_name
    end
    system = client.systems.update(system.id, system.version, name: room_name, display_name: room_display, email: email)
  end
  rooms[{level_idx, room_idx}] = system
end

# ================================
# Locate drivers
# ================================
puts "========================="
puts "Locating required drivers"

LOGIC_DRIVERS = {
  "graph"  => ["PlaceOS Room Events", "Booking to System Logic Module"],
  "booker" => ["PlaceOS Room Events", "Booking to System Resource Booker Logic Module"],
}

SHARED_DRIVERS = {
  "graph"  => "Microsoft Graph API",
  "booker" => "Syllabus Plus Resource Booker",
}

alias Driver = PlaceOS::Client::API::Models::Driver

available_drivers = client.drivers.search(limit: 1000)
driver_lookup = {} of String => Driver

# ensure all required drivers have been added to the cluster
(LOGIC_DRIVERS.values.flatten.uniq! + SHARED_DRIVERS.values).each do |name|
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
shared_added = 0
logic_added = 0

# driver name => module id
shared_modules = Hash(String, Module).new do |hash, name|
  driver = driver_lookup[name]
  modules = client.modules.search(driver_id: driver.id)
  puts "   missing shared module for driver: #{name}" if modules.empty?
  hash[name] = modules.first
end

entries.each do |entry|
  room_id = "#{entry.level}.#{entry.room.to_s.rjust(2, '0')}"
  puts " > checking #{entry.description} #{room_id}"
  mod_checked += 1

  # find driver
  uuid_string = entry.email.split("@")[0]
  room_type = "booker"

  begin
    uuid = UUID.new(uuid_string)
  rescue
    # if it's not a valid UUID then it's a graph API meeting room
    room_type = "graph"
  end

  driver_name = SHARED_DRIVERS[room_type]
  puts "   checking #{driver_name} exists (#{room_type})"
  mod = shared_modules[driver_name]
  system = rooms[{entry.level, entry.room}]

  # check if module already exists
  mod_id = system.modules.find { |e_mod| e_mod == mod.id }
  next if mod_id

  puts "   adding shared module"

  modules = system.modules
  modules << mod.id
  system = client.systems.update(system.id, system.version, modules: modules)
  shared_added += 1

  modules = existing_modules[system.id]
  LOGIC_DRIVERS[room_type].each do |name|
    puts " > checking #{name} in #{room_id}"
    driver = driver_lookup[name]
    mod = modules.find { |e_mod| e_mod.driver_id == driver.id }
    mod_checked += 1

    next if mod

    puts "   creating module"

    # logic modules automatically added to systems
    client.modules.create(driver.id, control_system_id: system.id)
    logic_added += 1
  end
end

puts "=============================="
puts "COMPLETE"
puts "=============================="

puts "zones created: #{zones_added}"
puts "systems created: #{systems_added}"
puts "logic modules created: #{logic_added}"
puts "shared modules added: #{shared_added}"
puts "modules checked: #{mod_checked}"
