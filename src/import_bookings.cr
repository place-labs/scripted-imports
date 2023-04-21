require "option_parser"
require "placeos"

# defaults if you don't want to use command line options
api_key = "4abedae4e97dced85219feb2f0f1"
place_domain = "http://my.placeos.domain"

# calendar is shared
calendar_module_id = "mod-FSqCVJUOP48"

# each room has it's own instance of a driver
bookings_driver_id = "driver-FTIqL3xTyeD"

# Command line options
OptionParser.parse do |parser|
  parser.banner = "Usage: #{PROGRAM_NAME} [arguments]"

  parser.on("-m MODULE_ID", "--module=MODULE_ID", "the calendar module id to be shared in all bookable spaces") do |mod|
    calendar_module_id = mod
  end

  parser.on("-b DRIVER_ID", "--booking=DRIVER_ID", "the bookings driver that we want in each room") do |driver|
    bookings_driver_id = driver
  end

  parser.on("-d DOMAIN", "--domain=DOMAIN", "the domain of the PlaceOS server") do |dom|
    place_domain = dom
  end

  parser.on("-k API_KEY", "--api_key=API_KEY", "placeos API key for access") do |k|
    api_key = k
  end

  parser.on("-h", "--help", "Show this help") do
    puts parser
    exit 0
  end
end

# Configure the PlaceOS client
client = PlaceOS::Client.new(place_domain,
  x_api_key: api_key,
  insecure: true, # if using a self signed certificate
)

system_count = 0
created = 0
updated = 0
errors = 0
puts "grabbing level zones..."

# Grab all the zones
zones = client.zones.search(limit: 1000, tags: "level")
puts "found #{zones.size} zones"

zones.each do |zone|
  puts "checking systems in #{zone.name}..."

  # Grab the systems in each zone
  systems = client.systems.search(limit: 1000, zone_id: zone.id)
  system_count += systems.size

  # Make sure all the systems have the calendar module and a bookings driver - if email set
  systems.each do |system|
    next unless system.email.presence

    if !system.modules.includes?(calendar_module_id)
      system.modules << calendar_module_id
      begin
        # system version provided for compare-and-swap
        client.systems.update(
          id: system.id,
          version: system.version,
          modules: system.modules,
        )
        updated += 1
      rescue error
        errors += 1
        puts error.inspect_with_backtrace
      end
    end

    # check if the any of the modules are a Bookings module
    modules = system.modules.dup
    modules.delete(calendar_module_id) # we can safely ignore this
    module_found = false
    modules.each do |mod_id|
      if client.modules.fetch(mod_id).driver_id == bookings_driver_id
        module_found = true
        break
      end
    end

    # Add the module to the system
    if !module_found
      module_id = client.modules.create(
        driver_id: bookings_driver_id,
        control_system_id: system.id,
      ).id

      begin
        client.modules.start(module_id)
      rescue
        puts "failed to start #{module_id}"
        errors += 1
      end

      created += 1
    end
  end
end

puts "\nchecked #{system_count} systems,\nupdated #{updated} systems,\ncreated #{created} modules."

if errors == 0
  puts "success"
else
  puts "#{errors} errors"
end
