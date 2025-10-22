`model tsunami

// Define the grid first, before global
// CRITICAL: This grid represents the rasterized version of the GIS data
// Similar to NetLogo's patches system
grid cell_grid width: 100 height: 100 neighbors: 8 {
    bool is_land <- false;
    bool is_road <- false;  // Match NetLogo's road? attribute - CRITICAL for movement constraint
    bool is_flooded <- false;
    int shelter_id <- -1;
    float distance_to_safezone <- float(100000.0);
    rgb color <- ocean_color;
    float flood_intensity <- 0.0;
    
    aspect default {
        draw shape color: is_flooded ? rgb(0, 0, 255, flood_intensity) : color border: #black;
    }
}

global {
    // GIS and data files
    file building_shapefile <- file("../includes/buildings.shp");
    file road_shapefile <- file("../includes/roads.shp");
    file shelter_csvfile <- csv_file("../includes/shelters.csv", ",");
    
    // Image files for species
    file car_icon <- file("../includes/car-2897.png");
    file boat_icon <- file("../includes/ship-1051.png");
    
    // Environment parameters
    geometry shape <- envelope(building_shapefile);
    geometry land_area;
    geometry valid_area;
    
    // Lists for shelter management
    list<point> shelter_locations;
    list<float> shelter_capacities;
    list<int> current_shelter_occupancy;
    
    // Global parameters
    float max_distance_shelter <- 100000.0;
    int people_patch_threshold <- 10;  // max number of people per patch
    
    // Speed parameters (in m/s)
    float human_speed_avg <- 5.6;  // 20 km/h average human speed
    float human_speed_min <- 5.6;  // Minimum speed
    float human_speed_max <- 10.0; // 36 km/h maximum speed (running)
    
    // Population counts and sizes
    int locals_number <- 200;
    float locals_size <- 12.0;
    
    int tourists_number <- 100;
    float tourists_size <- 12.0;
    
    int rescuers_number <- 20;
    float rescuers_size <- 12.0;
    
    // Status counts for each population
    int locals_safe <- 0;
    int locals_dead <- 0;
    int locals_in_danger <- 0;
    
    int tourists_safe <- 0;
    int tourists_dead <- 0;
    int tourists_in_danger <- 0;
    
    int rescuers_safe <- 0;
    int rescuers_dead <- 0;
    int rescuers_in_danger <- 0;
    
    // Tourist strategy parameter
    string tourist_strategy <- "following rescuers or locals" among: ["wandering", "following rescuers or locals", "following crowd"];
    
    // Following crowd parameters
    float crowd_search_angle <- 45.0;  // Angle increment for crowd searching (degrees)
    float crowd_centroid_distance <- 7.5;  // Half of radius_look
    float crowd_centroid_radius <- 7.5;   // Half of radius_look
    
    // Tsunami parameters
    float tsunami_speed <- 44.3;  // m/s (sqrt(200*9.8) for shallow water)
    int tsunami_approach_time <- 460; // seconds (2 hours from Manila Trench to central VN)
    geometry tsunami_front;
    float coastal_x_coord;
    
    // Tsunami visualization parameters
    float wave_width <- 50.0; // Width of the visible wave effect
    geometry tsunami_shape;
    list<geometry> flood_areas;
    
    // Color parameters
    rgb land_color <- rgb(204, 175, 139);  // Light brown for land
    rgb ocean_color <- rgb(135, 206, 235);  // Light blue for ocean
    rgb road_color <- rgb(71, 71, 71);      // Dark grey for roads
    
    // Car parameters
    float car_speed_min <- 15.0;  // m/s (54 km/h)
    float car_speed_max <- 25.0;  // m/s (90 km/h)
    float car_acceleration <- 5.0;
    float car_deceleration <- 5.0;
    int cars_threshold_wait <- 5;
    string car_strategy <- "always go ahead" among: ["always go ahead", "go out when congestion"];
    
    // Car counters
    int cars_safe <- 0;
    int cars_dead <- 0;
    int cars_in_danger <- 0;
    int cars_number <- 10;
    rgb cars_safe_color <- #green;
    rgb cars_dead_color <- #red;
    rgb cars_in_danger_color <- #brown;
    
    // Boat parameters
    float boat_speed_min <- 2.0;  // m/s
    float boat_speed_max <- 10.0; // m/s
    float boat_rescue_radius <- 20.0;
    int boat_capacity <- 20;
    int boats_number <- 5;
    
    // Boat counters
    int boats_safe <- 0;
    int boats_dead <- 0;
    int boats_in_danger <- 0;
    
    // Car initialization
    action init_cars {
        create car number: cars_number {
            location <- any_location_in(one_of(road));
            cars_in_danger <- cars_in_danger + 1;
        }
    }
    
    // Boat initialization
    action init_boats {
        create boat number: boats_number {
            // Place boats in water areas
            point water_loc <- one_of(cell_grid where (!each.is_land)).location;
            location <- water_loc;
            boats_in_danger <- boats_in_danger + 1;
        }
    }
    
    // Add to global section
    int update_frequency <- 1; // Update every cycle by default
    
    // Add these variables to the global section
    bool simulation_complete <- false;
    int post_tsunami_delay <- 100; // Cycles to continue after tsunami passes through
    
    // Add tsunami segments parameters like NetLogo
    int tsunami_nb_segments <- 30;
    float tsunami_length_segment;
    list<float> tsunami_curr_coord <- [];
    list<float> tsunami_current_speed <- [];
    list<float> coastal_coord_x <- [];
    list<float> tsunami_curr_height <- []; // For future development
    
    // Tsunami speed parameters like NetLogo
    float tsunami_speed_avg <- 44.3;  // m/s
    float tsunami_speed_std <- 0.5;
    float scale_factor <- 1.0; // Will be calculated based on GIS
    
    init {
        // Create physical environment first
        create building from: building_shapefile {
            shape <- shape; 
        }
        create road from: road_shapefile;
        
        // Define land area (union of buildings and roads)
        land_area <- union(building collect each.shape, road collect each.shape);
        valid_area <- land_area;
        
        // Initialize water/land areas
        loop c over: cell_grid {
            if (c.shape intersects land_area) {
                c.color <- land_color;
                c.is_land <- true;
            } else {
                c.color <- ocean_color;
                c.is_land <- false;
            }
        }
        
        // Mark cells as roads - CRITICAL: Match NetLogo logic
        // This is equivalent to NetLogo's: if gis:intersects? roads self [set road? true]
        ask road {
            color <- road_color;
            // Mark all cells that intersect with this road geometry
            loop c over: cell_grid {
                if (c.shape intersects self.shape) {
                    c.is_road <- true;
                }
            }
        }
        
        // Draw buildings on top
        ask building {
            color <- rgb(120, 120, 120);  // Grey for buildings
        }
        
        // Initialize shelter system from CSV using exact coordinates
        matrix data <- matrix(shelter_csvfile);
        loop i from: 0 to: data.rows - 1 {
            create shelter {
                location <- {float(data[0,i]), float(data[1,i])};
                width <- float(data[2,i]);
                height <- float(data[3,i]);
                capacity <- float(data[4,i]);
                name <- string(data[5,i]);
                current_occupants <- 0;
            }
        }
        
        // Create initial populations
        create people number: locals_number {
            type <- "local";
            color <- #yellow;
            agent_size <- locals_size;
            speed <- rnd(human_speed_min, human_speed_max);
            is_safe <- false;
            is_dead <- false;
            location <- any_location_in(one_of(road));
        }
        locals_in_danger <- locals_number; // Initialize counter
        
        create people number: tourists_number {
            type <- "tourist";
            color <- #violet;
            agent_size <- tourists_size;
            speed <- rnd(human_speed_min, human_speed_max);
            is_safe <- false;
            is_dead <- false;
            radius_look <- 15.0 + rnd(-2.0, 2.0);
            leader <- nil;
            location <- any_location_in(one_of(road));
        }
        tourists_in_danger <- tourists_number; // Initialize counter
        
        create people number: rescuers_number {
            type <- "rescuer";
            color <- #turquoise;
            agent_size <- rescuers_size;
            speed <- rnd(human_speed_min, human_speed_max);
            is_safe <- false;
            is_dead <- false;
            radius_look <- 15.0 + rnd(-2.0, 2.0);
            nb_tourists_to_rescue <- 0;
            location <- any_location_in(one_of(road));
        }
        rescuers_in_danger <- rescuers_number; // Initialize counter
        
        // Initialize tsunami segments like NetLogo
        tsunami_length_segment <- world.shape.height / tsunami_nb_segments;
        
        // Calculate world bounds for proper positioning
        geometry world_envelope <- envelope(world.shape);
        float world_min_y <- world_envelope.location.y - world_envelope.height/2;
        float world_max_y <- world_envelope.location.y + world_envelope.height/2;
        float world_max_x <- world_envelope.location.x + world_envelope.width/2;
        
        loop i from: 0 to: tsunami_nb_segments - 1 {
            // Initial position (start from right edge + small offset, ensuring visibility)
            tsunami_curr_coord <- tsunami_curr_coord + (world_max_x + rnd(10.0, 50.0));
            
            // Each segment has slightly different speed
            tsunami_current_speed <- tsunami_current_speed + gauss(tsunami_speed_avg, tsunami_speed_std);
            tsunami_curr_height <- tsunami_curr_height + 0.0; // For future use
            
            // Calculate segment Y boundaries properly within world bounds
            float segment_y_min <- world_min_y + (tsunami_length_segment * i);
            float segment_y_max <- world_min_y + (tsunami_length_segment * (i + 1));
            
            // Ensure segment boundaries don't exceed world bounds
            segment_y_min <- max([world_min_y, segment_y_min]);
            segment_y_max <- min([world_max_y, segment_y_max]);
            
            // Find coastal coordinate for each segment
            float max_x_coastal <- world_envelope.location.x - world_envelope.width/2; // Start from left edge
            ask road where (
                each.location.y >= segment_y_min and
                each.location.y <= segment_y_max
            ) {
                if (location.x > max_x_coastal) {
                    max_x_coastal <- location.x;
                }
            }
            coastal_coord_x <- coastal_coord_x + (max_x_coastal + rnd(10.0, 30.0));
        }
        
        // Remove single tsunami initialization
        // tsunami_front and tsunami_shape will be handled per segment
        
        // Initialize cars
        do init_cars();
        
        // Initialize boats
        do init_boats();
    }
    
    // Sửa phần update_tsunami để đảm bảo tốc độ và màu sắc đồng nhất
    reflex update_tsunami when: cycle >= tsunami_approach_time {
        // Update each tsunami segment separately
        loop i from: 0 to: tsunami_nb_segments - 1 {
            float segment_speed <- tsunami_current_speed[i];
            float segment_coord <- tsunami_curr_coord[i];
            float coastal_x <- coastal_coord_x[i];
            
            // NEW LOGIC: Keep constant speed in ocean, only decrease when hitting land
            if (segment_coord >= coastal_x) {
                // Still in ocean - maintain CONSTANT speed (no randomness)
                tsunami_current_speed[i] <- tsunami_speed_avg; // Fixed speed in ocean
            } else {
                // Reached coast - decrease speed GRADUALLY
                if (segment_speed > 0) {
                    // More gradual deceleration (5-15 instead of 10-30)
                    segment_speed <- segment_speed - rnd(5.0, 15.0);
                    if (segment_speed < 0) {
                        segment_speed <- 0.0;
                    }
                    tsunami_current_speed[i] <- segment_speed;
                }
            }
            
            // Calculate scaled movement speed
            float tsunami_speed_scale <- segment_speed * scale_factor * 60.0 / 3.6;
            
            // Update segment position
            tsunami_curr_coord[i] <- segment_coord - tsunami_speed_scale * step;
            
            // Define segment boundaries properly within world bounds
            geometry world_envelope <- envelope(world.shape);
            float world_min_y <- world_envelope.location.y - world_envelope.height/2;
            float world_max_y <- world_envelope.location.y + world_envelope.height/2;
            float segment_y_min <- world_min_y + (tsunami_length_segment * i);
            float segment_y_max <- world_min_y + (tsunami_length_segment * (i + 1));
            
            // Ensure segment boundaries don't exceed world bounds
            segment_y_min <- max([world_min_y, segment_y_min]);
            segment_y_max <- min([world_max_y, segment_y_max]);
            
            // IMPROVED FLOODING LOGIC - 100% flooding in ocean, probabilistic on land
            ask cell_grid where (
                each.location.x >= tsunami_curr_coord[i] and
                each.location.y >= segment_y_min and
                each.location.y <= segment_y_max
            ) {
                if (!is_flooded) {
                    if (!is_land) {
                        // OCEAN - 100% guaranteed flooding for consistency
                        is_flooded <- true;
                        color <- #blue;
                        flood_intensity <- 0.6; // Higher intensity for ocean
                    } else if (shelter_id = -1) {
                        // LAND - probabilistic flooding (50% chance)
                        if (rnd(10) < 5) {
                            is_flooded <- true;
                            color <- rgb(0, 100, 255, 0.7); // Different blue for land
                            flood_intensity <- 0.3; // Lower initial intensity on land
                        }
                    }
                }
                
                // Intensity growth rates differ by terrain type
                if (is_flooded) {
                    if (!is_land) {
                        // OCEAN - fast intensity growth (70% chance)
                        if (rnd(10) < 7) {
                            flood_intensity <- min([1.0, flood_intensity + 0.2]);
                            color <- rgb(0, 0, int(255 * flood_intensity));
                        }
                    } else {
                        // LAND - slower intensity growth (40% chance)
                        if (rnd(10) < 4) {
                            flood_intensity <- min([0.8, flood_intensity + 0.1]);
                            color <- rgb(0, 100, int(200 * flood_intensity), 0.7);
                        }
                    }
                }
                
                // GUARANTEED flooding for cells far behind tsunami front
                if (!is_flooded and tsunami_curr_coord[i] - location.x > 50.0) {
                    is_flooded <- true;
                    if (!is_land) {
                        flood_intensity <- 1.0;
                        color <- rgb(0, 0, 200); // Deep blue for ocean
                    } else {
                        flood_intensity <- 0.7;
                        color <- rgb(0, 100, 180, 0.7); // Blue-gray for flooded land
                    }
                }
            }
            
            // Update road flooding consistently
            ask road where (
                each.location.x >= tsunami_curr_coord[i] and
                each.location.y >= segment_y_min and
                each.location.y <= segment_y_max
            ) {
                // Increased probability (70% instead of 50%)
                if (!is_flooded and rnd(10) < 7) {
                    is_flooded <- true;
                    color <- rgb(0, 0, 255, 0.8);
                }
            }
        }
    }
    
    // Display evacuation progress every 50 cycles
    reflex display_progress when: cycle >= tsunami_approach_time and (cycle mod 50 = 0) and not simulation_complete {
        int total_people <- locals_number + tourists_number + rescuers_number;
        int total_safe <- locals_safe + tourists_safe + rescuers_safe;
        int total_dead <- locals_dead + tourists_dead + rescuers_dead;
        int total_in_danger <- locals_in_danger + tourists_in_danger + rescuers_in_danger;
        
        write "=== Evacuation Progress (Cycle " + cycle + ") ===";
        write "Safe: " + total_safe + "/" + total_people + " (" + string(total_safe * 100.0 / total_people) + "%)";
        write "Casualties: " + total_dead + "/" + total_people + " (" + string(total_dead * 100.0 / total_people) + "%)";
        write "Still in danger: " + total_in_danger + "/" + total_people;
        
        // Show improved tsunami progress
        geometry world_envelope <- envelope(world.shape);
        float world_left_edge <- world_envelope.location.x - world_envelope.width/2;
        
        // Calculate coverage based on leftmost active segment
        float leftmost_active_tsunami <- world_envelope.location.x + world_envelope.width/2;
        int active_segments <- 0;
        int stopped_segments <- 0;
        
        loop i from: 0 to: tsunami_nb_segments - 1 {
            if (tsunami_current_speed[i] > 0.1) {
                active_segments <- active_segments + 1;
                if (tsunami_curr_coord[i] < leftmost_active_tsunami) {
                    leftmost_active_tsunami <- tsunami_curr_coord[i];
                }
            } else {
                stopped_segments <- stopped_segments + 1;
            }
        }
        
        float map_coverage <- (world_envelope.location.x + world_envelope.width/2 - leftmost_active_tsunami) / world_envelope.width * 100.0;
        map_coverage <- max([0.0, min([100.0, map_coverage])]);
        
        write "Tsunami coverage: " + string(map_coverage) + "% of map";
        write "Active segments: " + active_segments + "/" + tsunami_nb_segments + ", Stopped: " + stopped_segments;
    }

    // Check simulation end condition - improved logic
    reflex check_tsunami_end when: cycle >= tsunami_approach_time and not simulation_complete {
        geometry world_envelope <- envelope(world.shape);
        float world_left_edge <- world_envelope.location.x - world_envelope.width/2;
        
        // Method 1: Check if any segment has completely passed through the map
        bool tsunami_passed_through <- false;
        loop i from: 0 to: tsunami_nb_segments - 1 {
            // If any segment has moved past the left edge of the world
            if (tsunami_curr_coord[i] <= world_left_edge - wave_width) {
                tsunami_passed_through <- true;
                break;
            }
        }
        
        // Method 2: Check if all segments have zero speed (stopped moving)
        bool all_segments_stopped <- true;
        loop i from: 0 to: tsunami_nb_segments - 1 {
            if (tsunami_current_speed[i] > 0.1) { // Small threshold for floating point precision
                all_segments_stopped <- false;
                break;
            }
        }
        
        // Method 3: Calculate actual coverage based on leftmost active segment
        float leftmost_active_tsunami <- world_envelope.location.x + world_envelope.width/2; // Start from right edge
        loop i from: 0 to: tsunami_nb_segments - 1 {
            // Only consider segments that are still moving or within the world bounds
            if (tsunami_current_speed[i] > 0.1 or tsunami_curr_coord[i] > world_left_edge) {
                if (tsunami_curr_coord[i] < leftmost_active_tsunami) {
                    leftmost_active_tsunami <- tsunami_curr_coord[i];
                }
            }
        }
        
        float map_coverage <- (world_envelope.location.x + world_envelope.width/2 - leftmost_active_tsunami) / world_envelope.width * 100.0;
        map_coverage <- max([0.0, min([100.0, map_coverage])]);
        
        // End simulation when ANY of these conditions is met:
        if (tsunami_passed_through or all_segments_stopped or map_coverage >= 100.0) {
            write "=== SIMULATION COMPLETE ===";
            if (tsunami_passed_through) {
                write "Tsunami has passed through the map completely";
            } else if (all_segments_stopped) {
                write "All tsunami segments have stopped moving";
            } else {
                write "Tsunami has covered 100% of the map";
            }
            write "Final map coverage: " + string(map_coverage) + "%";
            write "Final Statistics:";
            write "- Locals: " + locals_safe + " safe, " + locals_dead + " casualties";
            write "- Tourists: " + tourists_safe + " safe, " + tourists_dead + " casualties";
            write "- Rescuers: " + rescuers_safe + " safe, " + rescuers_dead + " casualties";
            write "- Cars: " + cars_safe + " safe, " + cars_dead + " casualties";
            write "- Total evacuation rate: " + 
                string((locals_safe + tourists_safe + rescuers_safe) * 100.0 / 
                       (locals_number + tourists_number + rescuers_number)) + "%";
            
            simulation_complete <- true;
            do pause;
        }
    }
}

// Species definitions
species building {
    aspect default {
        draw shape color: #gray border: #black;
    }
}

species road {
    bool is_flooded <- false;
    
    aspect default {
        draw shape color: is_flooded ? rgb(0,0,255,0.8) : road_color width: 2.0;
    }
}

species shelter {
    float width;
    float height;
    float capacity;
    string name;
    int current_occupants;
    
    aspect default {
        draw circle(100) color: rgb(0,255,0,0.6) border: #black width: 2;
        draw triangle(100) color: #white border: #black;
        draw name size: 14 color: #black at: {location.x, location.y + 120};
    }
}

// Base species for all people (locals, tourists, rescuers)
species people skills: [moving] {
    string type;
    rgb color;
    float speed;
    bool is_safe;
    bool is_dead;
    float radius_look;
    people leader <- nil;
    int nb_tourists_to_rescue;
    float agent_size;
    
    bool is_valid_location(point new_loc) {
        cell_grid target_cell <- cell_grid closest_to new_loc;
        // Match NetLogo logic: can only move to cells that are:
        // 1. Within valid area
        // 2. On land (is_land = true)
        // 3. On road (is_road = true) - CRITICAL addition
        // 4. Not flooded
        return (valid_area covers new_loc) and 
               (target_cell != nil) and
               (target_cell.is_land) and 
               (target_cell.is_road) and
               (!target_cell.is_flooded);
    }
    
    // Death checking reflex - runs every step
    reflex check_death when: !is_dead and !is_safe {
        // Check if current location is flooded using both road and cell_grid
        road current_road <- road closest_to self;
        cell_grid current_cell <- cell_grid closest_to self;
        
        // Agent dies if either the road OR the cell is flooded
        if ((current_road != nil and current_road.is_flooded) or 
            (current_cell != nil and current_cell.is_flooded)) {
            is_dead <- true;
            color <- #red;
            
            // Update death counters based on agent type
            switch type {
                match "local" { 
                    locals_dead <- locals_dead + 1;
                    locals_in_danger <- locals_in_danger - 1;
                }
                match "tourist" { 
                    tourists_dead <- tourists_dead + 1;
                    tourists_in_danger <- tourists_in_danger - 1;
                }
                match "rescuer" { 
                    rescuers_dead <- rescuers_dead + 1;
                    rescuers_in_danger <- rescuers_in_danger - 1;
                }
            }
        }
    }
    
    // Safety checking reflex - runs every step
    reflex check_safety when: !is_dead and !is_safe {
        shelter closest_shelter <- shelter closest_to self;
        
        // Check if agent reached shelter
        if (self distance_to closest_shelter < 10.0) {
            // Check if shelter has capacity
            if (closest_shelter.current_occupants < closest_shelter.capacity) {
                is_safe <- true;
                color <- #green;
                closest_shelter.current_occupants <- closest_shelter.current_occupants + 1;
                location <- closest_shelter.location;
                
                // Update safety counters based on agent type
                switch type {
                    match "local" { 
                        locals_safe <- locals_safe + 1;
                        locals_in_danger <- locals_in_danger - 1;
                    }
                    match "tourist" { 
                        tourists_safe <- tourists_safe + 1;
                        tourists_in_danger <- tourists_in_danger - 1;
                    }
                    match "rescuer" { 
                        rescuers_safe <- rescuers_safe + 1;
                        rescuers_in_danger <- rescuers_in_danger - 1;
                    }
                }
            }
        }
    }
    
    // Different movement behaviors for each type
    reflex move when: !is_dead and !is_safe and (cycle mod update_frequency = 0) {
        switch type {
            match "local" {
                // Randomize speed each step like NetLogo
                speed <- gauss(speed, 1.0);
                if (speed < human_speed_min) { speed <- human_speed_min; }
                if (speed > human_speed_max) { speed <- human_speed_max; }
                
                point target <- (shelter closest_to self).location;
                path path_to_target <- topology(road) path_between (self.location, target);
                
                // Check if path exists and doesn't cross ocean
                if (path_to_target != nil) {
                    // Get next point in the path
                    point next_point <- first(path_to_target.vertices);
                    
                    // Match NetLogo: Check if next point is on land AND on road before moving
                    cell_grid next_cell <- cell_grid closest_to next_point;
                    if (next_cell != nil and next_cell.is_land and next_cell.is_road and !next_cell.is_flooded) {
                        do follow path: path_to_target speed: speed;
                    } else {
                        // Find a random land direction if path goes through ocean
                        bool found_valid_move <- false;
                        int safety_counter <- 0;
                        int max_safety <- 100; // Safety measure to prevent CPU hogging
                        
                        loop while: (not found_valid_move) {
                            // Try a random direction
                            float random_angle <- rnd(360.0);
                            point possible_move <- self.location + {cos(random_angle) * speed, sin(random_angle) * speed};
                            
                            // Match NetLogo: Check if the new point is on land AND on road
                            cell_grid possible_cell <- cell_grid closest_to possible_move;
                            if (possible_cell != nil and possible_cell.is_land and possible_cell.is_road and !possible_cell.is_flooded) {
                                // Try to find a new path from this point
                                location <- possible_move;
                                found_valid_move <- true;
                            }
                            
                            // Safety exit - prevents infinite loops but allows agent to try again next cycle
                            safety_counter <- safety_counter + 1;
                            if (safety_counter >= max_safety) {
                                break; // Exit this loop but the agent will try again next cycle
                            }
                        }
                    }
                }
            }
            match "tourist" {
                // Add random speed variation for tourists, similar to locals and rescuers
                // This matches the NetLogo implementation where all agents have randomized speed
                speed <- gauss(speed, 1.0);
                if (speed < human_speed_min) { speed <- human_speed_min; }
                if (speed > human_speed_max) { speed <- human_speed_max; }
                
                if (tourist_strategy = "wandering") {
                    // Wandering strategy: tourists move randomly
                    // Try to find a valid location with safety counter to prevent infinite loops
                    bool found_valid_location <- false;
                    int safety_counter <- 0;
                    int max_safety <- 100; // Safety measure to prevent CPU hogging
                    
                    loop while: (not found_valid_location) {
                        // Generate a random possible location
                        point possible_loc <- self.location + {rnd(-5,5) * speed, rnd(-5,5) * speed};
                        
                        // Check if location is valid (on land and within bounds)
                        if (is_valid_location(possible_loc)) {
                            location <- possible_loc;
                            found_valid_location <- true;
                        }
                        
                        // Safety exit - prevents infinite loops but allows agent to try again next cycle
                        safety_counter <- safety_counter + 1;
                        if (safety_counter >= max_safety) {
                            break; // Exit this loop but the agent will try again next cycle
                        }
                    }
                } else if (tourist_strategy = "following rescuers or locals") {
                    // Following strategy: tourists follow rescuers or locals
                    if (leader = nil) {
                        // Try to find a rescuer first (priority)
                        list<people> potential_leaders <- (people where (each.type = "rescuer")) at_distance radius_look;
                        if (empty(potential_leaders)) {
                            // If no rescuers nearby, look for locals
                            potential_leaders <- (people where (each.type = "local")) at_distance radius_look;
                        }
                        if (!empty(potential_leaders)) {
                            leader <- potential_leaders[0];
                        }
                    }
                    if (leader != nil) {
                        // Follow the leader using road network if possible
                        path path_to_leader <- topology(road) path_between (self.location, leader.location);
                        if (path_to_leader != nil) {
                            do follow path: path_to_leader speed: speed;
                        }
                    } else {
                        // No leader found, perform small random movement
                        point possible_loc <- self.location + {rnd(-1,1) * speed, rnd(-1,1) * speed};
                        if (is_valid_location(possible_loc)) {
                            location <- possible_loc;
                        }
                    }
                } else if (tourist_strategy = "following crowd") {
                    // Crowd following strategy: Move toward densest population areas
                    // Implementation follows exact NetLogo algorithm 
                    float centroid_distance <- radius_look / 2.0;
                    float centroid_radius <- radius_look / 2.0;
                    float angle_look <- 0.0;
                    int max_nb_crowd <- -1;
                    float best_angle <- -1.0;
                    bool can_move_angle <- false;
                    
                    // Check all 8 directions (45-degree increments like NetLogo)
                    loop while: (angle_look < 360) {
                        // Step 1: Check if can move 1 step in this direction
                        float check_x <- location.x + cos(angle_look) * 1.0;
                        float check_y <- location.y + sin(angle_look) * 1.0;
                        point check_point <- {check_x, check_y};
                        
                        // Find the cell at this check point
                        cell_grid check_cell <- cell_grid closest_to check_point;
                        can_move_angle <- false;
                        
                        // Match NetLogo: can-people-move-to-patch checks road? and flooded? and threshold
                        if (check_cell != nil and check_cell.is_land and check_cell.is_road and !check_cell.is_flooded) {
                            // Check if people can move to this patch (equivalent to can-people-move-to-patch)
                            int people_count <- length(people overlapping check_cell);
                            if (people_count <= people_patch_threshold) {
                                can_move_angle <- true;
                            }
                        }
                        
                        // Step 2: If can move, check crowd density at centroid
                        if (can_move_angle) {
                            float centroid_x <- location.x + cos(angle_look) * centroid_distance;
                            float centroid_y <- location.y + sin(angle_look) * centroid_distance;
                            point centroid_point <- {centroid_x, centroid_y};
                            
                            // Count tourists and locals in radius around this centroid point
                            list<people> crowd_people <- people where (
                                (each.type = "tourist" or each.type = "local") and 
                                (each distance_to centroid_point <= centroid_radius)
                            );
                            int nb_crowd <- length(crowd_people);
                            
                            // Step 3: Update best direction
                            if (nb_crowd > max_nb_crowd) {
                                max_nb_crowd <- nb_crowd;
                                best_angle <- angle_look;
                            }
                        }
                        
                        // Increment angle by 45 degrees like NetLogo
                        angle_look <- angle_look + 45.0;
                    }
                    
                    // Step 4: Move towards best direction if found
                    if (best_angle >= 0) {
                        float target_x <- location.x + cos(best_angle) * speed;
                        float target_y <- location.y + sin(best_angle) * speed;
                        point target <- {target_x, target_y};
                        
                        // Match NetLogo: Validate target location is on road
                        if (valid_area covers target) {
                            cell_grid target_cell <- cell_grid closest_to target;
                            if (target_cell != nil and target_cell.is_land and target_cell.is_road and !target_cell.is_flooded) {
                                location <- target;
                            }
                        }
                    }
                }
            }
            match "rescuer" {
                // Randomize speed each step like locals and tourists (matching NetLogo behavior)
                speed <- gauss(speed, 1.0);
                if (speed < human_speed_min) { speed <- human_speed_min; }
                if (speed > human_speed_max) { speed <- human_speed_max; }
                
                // SAFETY CHECK: Calculate distance to nearest tsunami segment
                float min_tsunami_distance <- 999999.0;
                bool immediate_danger <- false;
                
                // Check current cell flooding status
                cell_grid current_cell <- cell_grid closest_to self;
                road current_road <- road closest_to self;
                if ((current_cell != nil and current_cell.is_flooded) or 
                    (current_road != nil and current_road.is_flooded)) {
                    immediate_danger <- true;
                }
                
                // Calculate minimum distance to any tsunami segment
                loop i from: 0 to: tsunami_nb_segments - 1 {
                    float distance_to_tsunami <- abs(location.x - tsunami_curr_coord[i]);
                    if (distance_to_tsunami < min_tsunami_distance) {
                        min_tsunami_distance <- distance_to_tsunami;
                    }
                }
                
                // EMERGENCY EVACUATION: If tsunami is too close (<150m) or immediate danger, evacuate
                if (immediate_danger or min_tsunami_distance < 150.0) {
                    // Force evacuation to nearest shelter with increased speed
                    point target <- (shelter closest_to self).location;
                    path path_to_target <- topology(road) path_between (self.location, target);
                    
                    if (path_to_target != nil and !empty(path_to_target.vertices)) {
                        // Emergency evacuation with 50% speed boost
                        do follow path: path_to_target speed: (speed * 1.5);
                    } else {
                        // Direct movement if no path available
                        do goto target: target speed: (speed * 1.5);
                    }
                } else {
                    // NORMAL RESCUE OPERATIONS: Continue rescue mission when safe distance
                    
                    // Find nearby tourists within radius_look (matching NetLogo: count tourists in-radius radius_look)
                    list<people> nearby_tourists <- (people where (each.type = "tourist" and !each.is_safe and !each.is_dead)) at_distance radius_look;
                    
                    if (!empty(nearby_tourists)) {
                        // STRATEGY 1: Lead tourists to shelter when found
                        // This matches NetLogo logic: when nb_tourists > 0, rescuer leads tourists to safety
                        point target <- (shelter closest_to self).location;
                        path path_to_target <- topology(road) path_between (self.location, target);
                        
                        if (path_to_target != nil and !empty(path_to_target.vertices)) {
                            // Follow path with normal speed when guiding tourists
                            do follow path: path_to_target speed: speed;
                        } else {
                            // Fallback: direct movement if no path found
                            do goto target: target speed: speed;
                        }
                        
                        // Keep normal speed when guiding tourists (no speed boost needed for safety)
                        // Speed remains as randomized: gauss(speed, 1.0) like NetLogo
                        
                    } else {
                        // STRATEGY 2: Wandering search pattern for tourists
                        // SPEED BOOST: Increase speed by 20% when searching (matches NetLogo: 1.2 * speed)
                        float wandering_speed <- gauss(speed * 1.2, 1.0);
                        
                        // Ensure speed stays within defined limits
                        if (wandering_speed < human_speed_min) { wandering_speed <- human_speed_min; }
                        if (wandering_speed > human_speed_max) { wandering_speed <- human_speed_max; }
                        
                        // 8-direction search pattern (matches NetLogo's 45° increments)
                        float angle_look <- 0.0;
                        bool found_valid_move <- false;
                        point target_location <- location;
                        
                        // Search in 8 directions (0°, 45°, 90°, 135°, 180°, 225°, 270°, 315°)
                        loop while: (angle_look < 360 and !found_valid_move) {
                            float target_x <- location.x + cos(angle_look) * wandering_speed;
                            float target_y <- location.y + sin(angle_look) * wandering_speed;
                            point potential_target <- {target_x, target_y};
                            
                            // Check if target location is valid (on land/road and not flooded)
                            cell_grid target_cell <- cell_grid closest_to potential_target;
                            // Match NetLogo: can-people-move-to-patch checks road? and flooded?
                            if (target_cell != nil and target_cell.is_land and target_cell.is_road and !target_cell.is_flooded) {
                                target_location <- potential_target;
                                found_valid_move <- true;
                            }
                            
                            angle_look <- angle_look + 45.0; // 45° increments like NetLogo
                        }
                        
                        // Move to the found location with boosted wandering speed
                        if (found_valid_move) {
                            location <- target_location;
                        } else {
                            // Fallback: random movement if no valid direction found in 8-direction search
                            float random_angle <- rnd(360.0);
                            float move_distance <- wandering_speed * 0.5; // Reduce distance for safety
                            point fallback_target <- location + {cos(random_angle) * move_distance, sin(random_angle) * move_distance};
                            
                            // Match NetLogo: check road? for fallback movement
                            cell_grid fallback_cell <- cell_grid closest_to fallback_target;
                            if (fallback_cell != nil and fallback_cell.is_land and fallback_cell.is_road and !fallback_cell.is_flooded) {
                                location <- fallback_target;
                            }
                        }
                    }
                }
            }
        }
    }
    
    aspect default {
        draw circle(agent_size * 5) color: is_dead ? #red : (is_safe ? #green : color) border: #black;
    }
}

// Car species definition
species car skills: [moving] {
    bool is_dead <- false;
    bool is_safe <- false;
    rgb color <- #brown;
    float speed <- rnd(car_speed_min, car_speed_max);
    int nb_people_in <- 1 + rnd(3);  // 1-4 people in car
    float cars_time_wait <- 0.0;
    
    aspect default {
        draw car_icon size: {150,100} rotate: heading at: location;  // Much larger size
    }
    
    reflex check_safety when: !is_dead and !is_safe {
        shelter nearest_shelter <- shuffle(shelter) first_with (each distance_to self < 10.0);
        if (nearest_shelter != nil) {
            if (nearest_shelter.current_occupants + nb_people_in <= nearest_shelter.capacity) {
                is_safe <- true;
                color <- #green;
                nearest_shelter.current_occupants <- nearest_shelter.current_occupants + nb_people_in;
                location <- nearest_shelter.location;
                cars_safe <- cars_safe + 1;
                cars_in_danger <- cars_in_danger - 1;
            }
        }
    }
    
    reflex move when: !is_dead and !is_safe and (cycle mod update_frequency = 0) {
        // Strategy 1: Always go ahead
        if (car_strategy = "always go ahead") {
            shelter target_shelter <- shuffle(shelter) with_min_of (each distance_to self);
            path path_to_target <- topology(road) path_between (self.location, target_shelter.location);
            
            if (path_to_target != nil and !empty(path_to_target.vertices)) {
                // Check if next point is on land (ocean avoidance)
                point next_point <- first(path_to_target.vertices);
                
                // Match NetLogo: can-cars-move-to-patch checks road? and flooded?
                cell_grid next_cell <- cell_grid closest_to next_point;
                if (next_cell != nil and next_cell.is_land and next_cell.is_road and !next_cell.is_flooded) {
                    // Check for agents blocking the way
                    list<people> people_ahead <- people at_distance 5.0;
                    list<car> cars_ahead <- car at_distance 5.0;
                    
                    if (!empty(people_ahead) or !empty(cars_ahead)) {
                        // Path is blocked, wait in place
                        // Could add a waiting animation or state indicator here
                    } else {
                        // Path is clear, adjust speed and move
                        // Speed up if no car ahead
                        speed <- speed + car_acceleration;
                        // Clamp speed
                        speed <- min([max([speed, car_speed_min]), car_speed_max]);
                        do follow path: path_to_target speed: speed;
                    }
                } else {
                    // Next point is in ocean, find random land movement
                    int safety_counter <- 0;
                    int max_safety <- 100; // Safety measure to prevent CPU hogging
                    bool found_valid_move <- false;
                    
                    loop while: (not found_valid_move) {
                        float random_angle <- rnd(360.0);
                        point possible_move <- self.location + {cos(random_angle) * speed, sin(random_angle) * speed};
                        
                        // Match NetLogo: cars need road? = true to move
                        cell_grid possible_cell <- cell_grid closest_to possible_move;
                        if (possible_cell != nil and possible_cell.is_land and possible_cell.is_road and !possible_cell.is_flooded) {
                            location <- possible_move;
                            found_valid_move <- true;
                        }
                        
                        // Safety exit - prevents infinite loops but allows agent to try again next cycle
                        safety_counter <- safety_counter + 1;
                        if (safety_counter >= max_safety) {
                            break; // Exit this loop but the agent will try again next cycle
                        }
                    }
                }
            }
        }
        // Strategy: Go out when congestion
        else if (car_strategy = "go out when congestion") {
            shelter target_shelter <- shuffle(shelter) with_min_of (each distance_to self);
            path path_to_target <- topology(road) path_between (self.location, target_shelter.location);
            
            if (path_to_target != nil and !empty(path_to_target.vertices)) {
                // Check if next point is on land
                point next_point <- first(path_to_target.vertices);
                
                // Match NetLogo: can-cars-move-to-patch checks road? and flooded?
                cell_grid next_cell <- cell_grid closest_to next_point;
                if (next_cell != nil and next_cell.is_land and next_cell.is_road and !next_cell.is_flooded) {
                    // Check for people or cars ahead
                    list<people> people_ahead <- people at_distance 5.0;
                    list<car> cars_ahead <- car at_distance 5.0;
                    
                    if (!empty(people_ahead) or !empty(cars_ahead)) {
                        // There are agents blocking the way
                        cars_time_wait <- cars_time_wait + 1;
                        
                        if (cars_time_wait >= cars_threshold_wait) {
                            // Create people from car occupants
                            create people number: nb_people_in {
                                type <- "local";
                                location <- myself.location;
                                color <- #yellow;
                                is_dead <- false;
                                is_safe <- false;
                                speed <- rnd(human_speed_min, human_speed_max);
                            }
                            cars_in_danger <- cars_in_danger - 1;
                            do die;
                        }
                    } else {
                        // Path is clear
                        cars_time_wait <- 0;
                        speed <- speed + car_acceleration;
                        speed <- min([max([speed, car_speed_min]), car_speed_max]);
                        do follow path: path_to_target speed: speed;
                    }
                } else {
                    // Next point is in ocean, use random land movement
                    int safety_counter <- 0;
                    int max_safety <- 100; // Safety measure to prevent CPU hogging
                    bool found_valid_move <- false;
                    
                    loop while: (not found_valid_move) {
                        float random_angle <- rnd(360.0);
                        point possible_move <- self.location + {cos(random_angle) * speed, sin(random_angle) * speed};
                        
                        // Match NetLogo: cars need road? = true to move
                        cell_grid possible_cell <- cell_grid closest_to possible_move;
                        if (possible_cell != nil and possible_cell.is_land and possible_cell.is_road and !possible_cell.is_flooded) {
                            location <- possible_move;
                            found_valid_move <- true;
                        }
                        
                        // Safety exit - prevents infinite loops but allows agent to try again next cycle
                        safety_counter <- safety_counter + 1;
                        if (safety_counter >= max_safety) {
                            break; // Exit this loop but the agent will try again next cycle
                        }
                    }
                }
            }
        }
    }
}

// Boat species definition
species boat skills: [moving] {
    bool is_dead <- false;
    bool is_safe <- false;
    rgb color <- #blue;
    float speed <- rnd(boat_speed_min, boat_speed_max);
    
    aspect default {
        draw boat_icon size: {200,150} rotate: heading at: location;
    }
}

experiment tsunami_simulation type: gui {
    parameter "Number of locals" var: locals_number min: 0 max: 10000;
    parameter "Number of tourists" var: tourists_number min: 0 max: 5000;
    parameter "Number of rescuers" var: rescuers_number min: 0 max: 1000;
    parameter "Tourist Movement Strategy" var: tourist_strategy among: ["wandering", "following rescuers or locals", "following crowd"] init: "following rescuers or locals";
    parameter "Car Movement Strategy" var: car_strategy among:["always go ahead", "go out when congestion"];
    parameter "Tsunami segments" var: tsunami_nb_segments min: 1 max: 50;
    parameter "Tsunami approach time" var: tsunami_approach_time min: 0 max: 1000;
    parameter "Average tsunami speed" var: tsunami_speed_avg min: 10.0 max: 100.0;
    
    output {
        display main_display type: opengl axes: false {
            overlay position: { 5, 5 } size: { 180, 20 } background: #black transparency: 0.5 {
                draw "Tsunami Evacuation Model" at: { 10, 15 } color: #white font: font("Arial", 16, #bold);
            }
            
            // Draw background and infrastructure
            species cell_grid aspect: default transparency: 0.3;
            species building aspect: default transparency: 0.7;
            species road aspect: default;
            
            // Draw vehicles and people
            species car aspect: default transparency: 0.0;  // No transparency for vehicles
            species boat aspect: default transparency: 0.0;
            species people aspect: default;
            species shelter aspect: default;
            
            // Draw tsunami on top
            graphics "tsunami" {
                if cycle >= tsunami_approach_time {
                    draw tsunami_shape color: rgb(0,0,255,0.5) border: rgb(0,0,255,0.8);
                }
            }
            
            // Draw tsunami segments visualization
            graphics "tsunami_segments" {
                if (cycle >= tsunami_approach_time) {
                    float uniform_opacity <- 0.8; // Higher consistent opacity
                    
                    loop i from: 0 to: tsunami_nb_segments - 1 {
                        // Calculate segment boundaries
                        geometry world_envelope <- envelope(world.shape);
                        float world_min_y <- world_envelope.location.y - world_envelope.height/2;
                        float world_max_y <- world_envelope.location.y + world_envelope.height/2;
                        float segment_y_min <- world_min_y + (tsunami_length_segment * i);
                        float segment_y_max <- world_min_y + (tsunami_length_segment * (i + 1));
                        
                        // Ensure segments have appropriate height
                        segment_y_min <- max([world_min_y, segment_y_min]);
                        segment_y_max <- min([world_max_y, segment_y_max]);
                        float actual_segment_height <- segment_y_max - segment_y_min;
                        
                        // Force minimum segment height for edge segments
                        if (actual_segment_height < tsunami_length_segment * 0.5) {
                            if (i = 0) {
                                segment_y_min <- max([world_min_y, segment_y_max - tsunami_length_segment]);
                            } else if (i = tsunami_nb_segments - 1) {
                                segment_y_max <- min([world_max_y, segment_y_min + tsunami_length_segment]);
                            }
                            actual_segment_height <- segment_y_max - segment_y_min;
                        }
                        
                        // Only draw if segment is within bounds
                        if (actual_segment_height > 0 and 
                            tsunami_curr_coord[i] > world_envelope.location.x - world_envelope.width/2 - wave_width and
                            tsunami_curr_coord[i] < world_envelope.location.x + world_envelope.width/2 + wave_width) {
                            
                            float segment_opacity <- uniform_opacity;
                            
                            // Ocean vs Land opacity difference
                            cell_grid nearest_cell <- cell_grid closest_to {tsunami_curr_coord[i], (segment_y_min + segment_y_max) / 2};
                            if (nearest_cell != nil and nearest_cell.is_land) {
                                // Reduce opacity on land
                                segment_opacity <- uniform_opacity * 0.7;
                            }
                            
                            // Draw main segment
                            geometry segment_shape <- rectangle(wave_width, actual_segment_height) 
                                at_location {tsunami_curr_coord[i], (segment_y_min + segment_y_max) / 2};
                            draw segment_shape color: rgb(0, 0, 255, segment_opacity) border: #transparent;
                            
                            // Better blending between segments
                            if (i > 0) {
                                // Calculate middle point between current and previous segment
                                float mid_x <- (tsunami_curr_coord[i] + tsunami_curr_coord[i-1])/2;
                                
                                // Create overlap for smoother transition
                                float overlap_height <- tsunami_length_segment * 0.2; // 20% overlap
                                geometry overlap_shape <- rectangle(wave_width/2, overlap_height)
                                    at_location {mid_x, segment_y_min + overlap_height/2};
                                
                                // Draw overlap with average opacity
                                draw overlap_shape color: rgb(0, 0, 255, segment_opacity * 0.8) border: #transparent;
                            }
                        }
                    }
                }
            }
            
            graphics "Legend" {
                float x <- world.shape.width * 0.8;
                float y <- world.shape.height * 0.95;
                
//                draw "Shelter" at: {x, y} color: #black font: font("Arial", 14, #bold);
//                draw circle(10) at: {x + 50, y} color: rgb(0, 255, 0, 0.6) border: #black;
                
                // Population counts
//                draw "Locals: " + length(people where (each.type = "local")) at: {x, y - 30} color: #black;
//                draw "Tourists: " + length(people where (each.type = "tourist")) at: {x, y - 50} color: #black;
//                draw "Rescuers: " + length(people where (each.type = "rescuer")) at: {x, y - 70} color: #black;
//                draw "Cars: " + length(car) at: {x, y - 90} color: #black;
//                draw "Boats: " + length(boat) at: {x, y - 110} color: #black;
            }
        }
        
        monitor "Safe locals" value: locals_safe;
        monitor "Dead locals" value: locals_dead;
        monitor "In danger locals" value: locals_in_danger;
        monitor "Safe tourists" value: tourists_safe;
        monitor "Dead tourists" value: tourists_dead;
        monitor "In danger tourists" value: tourists_in_danger;
        monitor "Safe rescuers" value: rescuers_safe;
        monitor "Dead rescuers" value: rescuers_dead;
        monitor "In danger rescuers" value: rescuers_in_danger;
        monitor "Safe cars" value: cars_safe;
        monitor "Dead cars" value: cars_dead;
        monitor "Safe boats" value: boats_safe;
        monitor "Dead boats" value: boats_dead;
        
        // Overall status histogram chart with percentages - updates automatically
        display "Overall Safety Status" {
            chart "Population Status Percentages" type: histogram {
                data "Safe (%)" value: (locals_number + tourists_number + rescuers_number > 0 ? 
                    ((locals_safe + tourists_safe + rescuers_safe) * 100.0 / (locals_number + tourists_number + rescuers_number)) : 0.0) color: #green;
                data "Dead (%)" value: (locals_number + tourists_number + rescuers_number > 0 ? 
                    ((locals_dead + tourists_dead + rescuers_dead) * 100.0 / (locals_number + tourists_number + rescuers_number)) : 0.0) color: #red;
                data "Danger (%)" value: (locals_number + tourists_number + rescuers_number > 0 ? 
                    ((locals_in_danger + tourists_in_danger + rescuers_in_danger) * 100.0 / (locals_number + tourists_number + rescuers_number)) : 0.0) color: #orange;
            }
        }
        display "Death Percentage Chart" {
        chart "Death Percentage by Population" type: histogram {
                data "Locals Dead (%)" value: (locals_number > 0 ? (locals_dead * 100.0 / locals_number) : 0.0) color: #red;
                data "Tourists Dead (%)" value: (tourists_number > 0 ? (tourists_dead * 100.0 / tourists_number) : 0.0) color: #violet;
                data "Rescuers Dead (%)" value: (rescuers_number > 0 ? (rescuers_dead * 100.0 / rescuers_number) : 0.0) color: #blue;
            }
        }
    }
}