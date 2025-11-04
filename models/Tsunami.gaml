model tsunami

// Define the grid first, before global
// CRITICAL: This grid represents the rasterized version of the GIS data
// Similar to NetLogo's patches system
grid cell_grid width: 100 height: 100 neighbors: 8 {
    bool is_land <- false;
    bool is_road <- false;  // Match NetLogo's road? attribute - CRITICAL for movement constraint
    bool is_flooded <- false;
    bool is_water <- false;  // NEW: Mark water bodies (ocean, rivers) for constraint enforcement
    int shelter_id <- -1;
    float distance_to_safezone <- float(100000.0);
    rgb color <- ocean_color;
    float flood_intensity <- 0.0;
    
    // OPTIMIZATION: Precomputed shelter information
    point nearest_shelter_location;
    float distance_to_nearest_shelter <- float(100000.0);
    
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
    
    // OPTIMIZATION: Add road network graph for proper navigation
    graph road_network;
    graph simplified_road_network;
    
    // Network cleaning enabled by default (replaces as_driving_graph approach)
    // clean_network will split roads at intersections to fix connectivity
    
    // Road network connectivity parameters
    float road_connection_tolerance <- 10.0 parameter: "Road connection tolerance (m)" category: "Network";
    int min_component_size <- 10 parameter: "Minimum component size" category: "Network";
    
    // OPTIMIZATION: Spatial indexing for fast neighbor lookups - OPTIMIZED for 5000 agents
    map<cell_grid, list<people>> people_spatial_index;
    map<cell_grid, list<car>> car_spatial_index;
    int spatial_index_update_frequency <- 15;  // Update every 15 cycles for better performance with 1000+ agents
    
    // OPTIMIZATION: Performance monitoring
    int total_pathfinding_calls <- 0;
    int cached_path_uses <- 0;
    float avg_pathfinding_time <- 0.0;
    bool enable_performance_stats <- true parameter: "Enable performance stats" category: "Debug";
    
    // OPTIMIZATION: Batch processing parameters - OPTIMIZED for 5000 agents
    int agent_batch_size <- 200 parameter: "Agent batch size for parallel processing" category: "Performance";
    bool enable_parallel_processing <- true parameter: "Enable parallel processing" category: "Performance";
    
    // OPTIMIZATION: Reduce update frequency for better performance with many agents
    int update_frequency <- 3 parameter: "Agent update frequency (cycles)" category: "Performance";
    
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
    float locals_size <- 5.0;
    
    int tourists_number <- 100;
    float tourists_size <- 5.0;
    
    int rescuers_number <- 20;
    float rescuers_size <- 5.0;
    
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
        // Use same spawn vertices as people
        list<point> connected_vertices <- simplified_road_network.vertices;
        list<point> all_vertices <- road_network.vertices;
        list<point> spawn_vertices <- empty(connected_vertices) ? all_vertices : connected_vertices;
        
        loop i from: 0 to: cars_number - 1 {
            create car {
                // CRITICAL: Spawn at graph vertex for pathfinding
                if (!empty(spawn_vertices)) {
                    location <- one_of(spawn_vertices);
                } else {
                    road r0 <- road closest_to self;
                    if (r0 != nil) {
                        location <- any_location_in(r0);
                        point nearest_vertex <- all_vertices with_min_of (each distance_to self);
                        if (nearest_vertex != nil) {
                            location <- nearest_vertex;
                        }
                    }
                }
                
                // Precompute target shelter (goto sẽ tự động snap target)
                shelter nearest_shelter <- shelter with_min_of (each distance_to self);
                my_target_shelter <- nearest_shelter;
                my_target_vertex <- nearest_shelter.location;  // goto sẽ snap tự động
                
                cars_in_danger <- cars_in_danger + 1;
            }
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
    
    // Add to global section - REMOVED (now defined above with optimization)
    
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
        
        // OPTIMIZATION: Create road network graph
        write "Building road network...";
        write "Original roads count: " + length(road);
        
        // CRITICAL FIX: Use clean_network to split roads at ALL intersections
        // This solves the connectivity problem (2100 components → expected <100)
        write "Cleaning road network topology...";
        float start_clean_time <- machine_time;
        
        list<geometry> cleaned_roads <- clean_network(
            road collect each.shape,        // Input: all road geometries
            road_connection_tolerance,      // Tolerance: 10.0m (merge nearby vertices)
            true,                            // split_lines: CRITICAL - split at intersections
            false                            // keepMainConnectedComponent: keep all components
        );
        
        float clean_duration <- machine_time - start_clean_time;
        write "Network cleaned in " + clean_duration + "ms";
        write "Cleaned geometries count: " + length(cleaned_roads);
        
        // VALIDATION: Check if cleaning succeeded (Linus review requirement)
        if (empty(cleaned_roads)) {
            write "ERROR: clean_network returned empty result, using original roads as fallback";
            // Fallback to original approach
            road_network <- as_edge_graph(road);
            map<road, float> road_weights <- road as_map (each::each.shape.perimeter);
            simplified_road_network <- as_edge_graph(road) with_weights road_weights;
        } else {
            // Replace old roads with cleaned roads
            write "Replacing roads with cleaned geometries...";
            ask road { do die; }
            
            loop cleaned_geom over: cleaned_roads {
                create road {
                    shape <- cleaned_geom;
                    is_flooded <- false;  // Initialize attribute (preserve road attributes)
                }
            }
            write "New roads created: " + length(road);
            
            // Performance check (Linus review requirement)
            if (length(road) > 15000) {
                write "WARNING: Road count very high (" + length(road) + "), may impact performance";
            }
            
            // Create graph using as_edge_graph (simpler than as_driving_graph)
            road_network <- as_edge_graph(road);
            map<road, float> road_weights <- road as_map (each::each.shape.perimeter);
            simplified_road_network <- as_edge_graph(road) with_weights road_weights;
            
            write "Graph created with " + length(road_network.vertices) + " vertices and " + 
                 length(road_network.edges) + " edges";
        }
        
        // IMPORTANT: Check graph connectivity
        write "Total roads: " + length(road);
        write "Graph vertices: " + length(simplified_road_network.vertices);
        write "Graph edges: " + length(simplified_road_network.edges);
        
        // Get connected components
        list<list> components <- connected_components_of(simplified_road_network);
        write "Number of disconnected road components: " + length(components);
        
        // Show component sizes (only if components exist)
        if (length(components) > 0) {
            list<int> component_sizes <- components collect length(each);
            component_sizes <- reverse(component_sizes sort_by each);
            int max_components_to_show <- min([length(component_sizes), 10]);
            loop i from: 0 to: max_components_to_show - 1 {
                write "  Component " + i + " size: " + component_sizes[i] + " nodes";
            }
        } else {
            write "  WARNING: No components found in graph";
        }
        
        if (length(components) > 1) {
            // IMPROVED: Use all components with at least min_component_size nodes
            list<list> major_components <- components where (length(each) >= min_component_size);
            
            if (length(major_components) > 0) {
                write "Using " + length(major_components) + " major components (size >= " + min_component_size + " nodes)";
                
                // Merge all major components
                list<point> all_major_nodes <- [];
                loop comp over: major_components {
                    all_major_nodes <- all_major_nodes + comp;
                }
                write "Total nodes in major components: " + length(all_major_nodes);
                
                // Filter roads to only those in major components
                list<road> connected_roads <- [];
                ask road {
                    bool in_component <- false;
                    loop pt over: shape.points {
                        if (all_major_nodes contains pt) {
                            in_component <- true;
                            break;
                        }
                    }
                    if (in_component) {
                        connected_roads << self;
                    }
                }
                
                // Rebuild graph with connected roads
                if (!empty(connected_roads)) {
                    write "Rebuilding graph with " + length(connected_roads) + " connected roads";
                    road_network <- as_edge_graph(connected_roads);
                    map<road, float> connected_weights <- connected_roads as_map (each::each.shape.perimeter);
                    simplified_road_network <- as_edge_graph(connected_roads) with_weights connected_weights;
                    write "New graph has " + length(simplified_road_network.vertices) + " vertices";
                }
            } else {
                write "WARNING: No large components found, using all roads";
            }
        }
        
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
        
        // Mark water cells (ocean, rivers) for constraint enforcement
        write "Marking water cells...";
        float start_time <- machine_time;
        ask cell_grid parallel: enable_parallel_processing {
            if (!is_land and !is_road) {
                is_water <- true;
            }
        }
        write "Water cells marked in " + (machine_time - start_time) + "ms";
        write "Total water cells: " + length(cell_grid where each.is_water);
        
        // Mark cells as roads - OPTIMIZED: Use spatial query instead of nested loop
        // This is equivalent to NetLogo's: if gis:intersects? roads self [set road? true]
        write "Marking road cells...";
        start_time <- machine_time;
        
        ask road parallel: enable_parallel_processing {
            color <- road_color;
            // OPTIMIZED: Use overlapping instead of looping through ALL cells
            list<cell_grid> intersecting_cells <- cell_grid overlapping self;
            ask intersecting_cells {
                is_road <- true;
            }
        }
        
        write "Road marking completed in " + (machine_time - start_time) + "ms";
        write "Total road cells: " + length(cell_grid where each.is_road);
        
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
        
        // NOTE: No need to precompute target vertices since goto auto-snaps to graph vertices
        write "Shelters initialized: " + length(shelter);
        
        // OPTIMIZATION: Precompute distances to nearest shelter for ALL cells
        // CRITICAL: Must precompute for all cells, not just road cells, because agents
        // may spawn on road segments that don't perfectly overlap road cells
        write "Precomputing shelter distances...";
        start_time <- machine_time;
        
        ask cell_grid parallel: enable_parallel_processing {
            shelter nearest <- shelter with_min_of (each distance_to self);
            if (nearest != nil) {
                nearest_shelter_location <- nearest.location;
                distance_to_nearest_shelter <- self distance_to nearest;
            }
        }
        
        write "Shelter distances precomputed in " + (machine_time - start_time) + "ms";
        
        // Create initial populations
        // CRITICAL FIX: Spawn agents at graph vertices to ensure pathfinding works
        // path_between requires start/end points to be vertices in the graph
        list<point> connected_vertices <- simplified_road_network.vertices;
        list<point> all_vertices <- road_network.vertices;
        
        write "DEBUG: Connected vertices available: " + length(connected_vertices);
        write "DEBUG: Total vertices available: " + length(all_vertices);
        
        // Use connected vertices first, fallback to all vertices if needed
        list<point> spawn_vertices <- empty(connected_vertices) ? all_vertices : connected_vertices;
        
        loop i from: 0 to: locals_number - 1 {
            create people {
                type <- "local";
                color <- #yellow;
                agent_size <- locals_size;
                speed <- rnd(human_speed_min, human_speed_max);
                is_safe <- false;
                is_dead <- false;
                // CRITICAL: Spawn at graph vertex, not random road point
                if (!empty(spawn_vertices)) {
                    location <- one_of(spawn_vertices);
                } else {
                    // Fallback: spawn on road and snap to nearest vertex
                    road r0 <- road closest_to self;
                    if (r0 != nil) {
                        location <- any_location_in(r0);
                        point nearest_vertex <- all_vertices with_min_of (each distance_to self);
                        if (nearest_vertex != nil) {
                            location <- nearest_vertex;
                        }
                    }
                }
                
                // Precompute target shelter (goto sẽ tự động snap target)
                shelter nearest_shelter <- shelter with_min_of (each distance_to self);
                my_target_shelter <- nearest_shelter;
                my_target_vertex <- nearest_shelter.location;  // goto sẽ snap tự động
            }
        }
        locals_in_danger <- locals_number;
        
        loop i from: 0 to: tourists_number - 1 {
            create people {
                type <- "tourist";
                color <- #violet;
                agent_size <- tourists_size;
                speed <- rnd(human_speed_min, human_speed_max);
                is_safe <- false;
                is_dead <- false;
                radius_look <- 15.0 + rnd(-2.0, 2.0);
                leader <- nil;
                // CRITICAL: Spawn at graph vertex
                if (!empty(spawn_vertices)) {
                    location <- one_of(spawn_vertices);
                } else {
                    road r0 <- road closest_to self;
                    if (r0 != nil) {
                        location <- any_location_in(r0);
                        point nearest_vertex <- all_vertices with_min_of (each distance_to self);
                        if (nearest_vertex != nil) {
                            location <- nearest_vertex;
                        }
                    }
                }
                
                // Precompute target shelter (goto automatically snaps to graph vertices)
                shelter nearest_shelter <- shelter with_min_of (each distance_to self);
                my_target_shelter <- nearest_shelter;
                my_target_vertex <- nearest_shelter.location;  // goto will auto-snap
            }
        }
        tourists_in_danger <- tourists_number;
        
        loop i from: 0 to: rescuers_number - 1 {
            create people {
                type <- "rescuer";
                color <- #turquoise;
                agent_size <- rescuers_size;
                speed <- rnd(human_speed_min, human_speed_max);
                is_safe <- false;
                is_dead <- false;
                radius_look <- 15.0 + rnd(-2.0, 2.0);
                nb_tourists_to_rescue <- 0;
                // CRITICAL: Spawn at graph vertex
                if (!empty(spawn_vertices)) {
                    location <- one_of(spawn_vertices);
                } else {
                    road r0 <- road closest_to self;
                    if (r0 != nil) {
                        location <- any_location_in(r0);
                        point nearest_vertex <- all_vertices with_min_of (each distance_to self);
                        if (nearest_vertex != nil) {
                            location <- nearest_vertex;
                        }
                    }
                }
                
                // Precompute target shelter (goto automatically snaps to graph vertices)
                shelter nearest_shelter <- shelter with_min_of (each distance_to self);
                my_target_shelter <- nearest_shelter;
                my_target_vertex <- nearest_shelter.location;  // goto will auto-snap
            }
        }
        rescuers_in_danger <- rescuers_number;
        
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
        
        // OPTIMIZATION: Initialize spatial indices
        people_spatial_index <- [];
        car_spatial_index <- [];
    }
    
    // OPTIMIZATION: Update spatial indices periodically
    // NOTE: Cannot use parallel processing here due to shared map modifications (race conditions)
    reflex update_spatial_indices when: (cycle mod spatial_index_update_frequency = 0) {
        // Clear old indices
        people_spatial_index <- [];
        car_spatial_index <- [];
        
        // Rebuild people spatial index - MUST BE SEQUENTIAL (shared map modification)
        ask people {
            cell_grid my_cell <- cell_grid closest_to self;
            if (my_cell != nil) {
                if (people_spatial_index.keys contains my_cell) {
                    people_spatial_index[my_cell] << self;
                } else {
                    people_spatial_index[my_cell] <- [self];
                }
            }
        }
        
        // Rebuild car spatial index - MUST BE SEQUENTIAL (shared map modification)
        ask car {
            cell_grid my_cell <- cell_grid closest_to self;
            if (my_cell != nil) {
                if (car_spatial_index.keys contains my_cell) {
                    car_spatial_index[my_cell] << self;
                } else {
                    car_spatial_index[my_cell] <- [self];
                }
            }
        }
    }
    
    // OPTIMIZATION: Display performance stats
    reflex display_performance when: enable_performance_stats and (cycle mod 100 = 0) and cycle > 0 {
        int total_calls <- total_pathfinding_calls + cached_path_uses;
        float cache_hit_rate <- total_calls > 0 ? (cached_path_uses * 100.0 / total_calls) : 0.0;
        
        // Count stuck agents (no movement for several cycles)
        int stuck_people <- 0;
        ask people where (!each.is_dead and !each.is_safe) {
            if (cycles_since_path_update > 20) { // Stuck for 20+ cycles
                stuck_people <- stuck_people + 1;
            }
        }
        
        write "=== Performance Stats (Cycle " + cycle + ") ===";
        write "Pathfinding calls: " + total_pathfinding_calls;
        write "Cached path uses: " + cached_path_uses;
        write "Cache hit rate: " + cache_hit_rate + "%";
        write "Avg pathfinding time: " + avg_pathfinding_time + "ms";
        write "Active people: " + length(people where (!each.is_dead and !each.is_safe));
        write "Stuck people (20+ cycles): " + stuck_people;
        write "Active cars: " + length(car where (!each.is_dead and !each.is_safe));
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
    
    // NOTE: target_vertex is deprecated (goto auto-snaps to graph vertices)
    // Kept for backward compatibility (can be removed later)
    point target_vertex <- location;
    
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
    
    // OPTIMIZATION: Precomputed target shelter and vertex
    shelter my_target_shelter;
    point my_target_vertex;
    
    // OPTIMIZATION: Path caching
    path current_path;
    point current_target;
    int path_recompute_interval <- 10;  // Recompute every 10 cycles
    int cycles_since_path_update <- 0;
    bool path_invalidated <- false;
    int path_validity_counter <- 0;
    
    // OPTIMIZATION: Multi-level pathfinding strategy (Solution 3 - IMPROVED)
    action get_path_to(point target) type: path {
        // CRITICAL: Check if target is nil to prevent NullPointerException
        if (target = nil) {
            return nil;
        }
        
        // Check if we need to recompute path (using path_validity_counter)
        bool need_recompute <- (current_path = nil) or 
                               (current_target = nil) or
                               (current_target distance_to target > 5.0) or
                               (path_validity_counter >= 15) or
                               path_invalidated;
        
        if (need_recompute) {
            float start_pathfinding <- machine_time;
            path new_path <- nil;
            string pathfinding_method <- "none";
            
            // CRITICAL FIX: Try simplified_road_network FIRST (guaranteed connected components)
            // This ensures both start and target are from the same network
            point start_vertex_simp <- simplified_road_network.vertices with_min_of (each distance_to location);
            point target_vertex_simp <- simplified_road_network.vertices with_min_of (each distance_to target);
            
            // LEVEL 1: Try simplified_road_network FIRST (connected components, 944 roads)
            if (start_vertex_simp != nil and target_vertex_simp != nil) {
                new_path <- path_between(simplified_road_network, start_vertex_simp, target_vertex_simp);
                if (new_path != nil and !empty(new_path.edges)) {
                    pathfinding_method <- "simplified";
                }
            }
            
            // LEVEL 2: Fallback to FULL road_network if simplified fails
            if (new_path = nil or empty(new_path.edges)) {
                point start_vertex_full <- road_network.vertices with_min_of (each distance_to location);
                point target_vertex_full <- road_network.vertices with_min_of (each distance_to target);
                
                if (start_vertex_full != nil and target_vertex_full != nil) {
                    new_path <- path_between(road_network, start_vertex_full, target_vertex_full);
                    if (new_path != nil and !empty(new_path.edges)) {
                        pathfinding_method <- "full_network";
                    }
                }
            }
            
            float pathfinding_time <- machine_time - start_pathfinding;
            
            // Update performance stats
            total_pathfinding_calls <- total_pathfinding_calls + 1;
            avg_pathfinding_time <- (avg_pathfinding_time + pathfinding_time) / 2.0;
            
            // Update cache
            current_path <- new_path;
            current_target <- target;
            path_validity_counter <- 0;
            path_invalidated <- false;
            cycles_since_path_update <- 0;
            
            return new_path;
        } else {
            // Use cached path
            cached_path_uses <- cached_path_uses + 1;
            path_validity_counter <- path_validity_counter + 1;
            cycles_since_path_update <- cycles_since_path_update + 1;
            return current_path;
        }
    }
    
    // OPTIMIZATION: Get nearby agents using spatial index
    list<people> get_nearby_people(float distance) {
        cell_grid my_cell <- cell_grid closest_to self;
        list<people> nearby <- [];
        
        if (my_cell != nil and (people_spatial_index.keys contains my_cell)) {
            nearby <- people_spatial_index[my_cell];
            
            // Also check neighboring cells
            ask my_cell.neighbors {
                if (people_spatial_index.keys contains self) {
                    nearby <- nearby + people_spatial_index[self];
                }
            }
            
            // Filter by actual distance - store reference to avoid 'myself' issue
            people current_agent <- self;
            nearby <- nearby where (each != current_agent and (each.location distance_to current_agent.location) <= distance);
        }
        
        return nearby;
    }
    
    // NEW: Get neighboring vertices for random network walk - OPTIMIZED VERSION
    list<point> get_neighboring_vertices {
        if (simplified_road_network = nil) {
            return [];
        }
        
        point current_vertex <- simplified_road_network.vertices with_min_of (each distance_to self);
        list<point> neighbors <- [];
        
        if (current_vertex != nil) {
            // OPTIMIZATION: Use neighbors_of operator instead of manual graph traversal
            // This is much faster than iterating through all edges
            try {
                neighbors <- simplified_road_network neighbors_of current_vertex;
            } catch {
                // FALLBACK: If neighbors_of fails, use manual method with distance constraint
                write "Warning: neighbors_of failed for " + name + ", using fallback method";
                list<point> nearby_vertices <- simplified_road_network.vertices where (
                    each != current_vertex and (each distance_to current_vertex) < 50.0
                );
                neighbors <- nearby_vertices;
            }
        }
        
        return neighbors;
    }
    
    // Check if location is valid for movement
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
        
        if (closest_shelter != nil) {
            float dist <- self distance_to closest_shelter;
            
            // DEBUG: Log when agents get close to shelters
            if (dist < 150.0 and cycle mod 50 = 0) {
                write "Agent " + type + " at distance " + dist + " from shelter " + closest_shelter.name + 
                      " (capacity: " + closest_shelter.current_occupants + "/" + closest_shelter.capacity + ")";
            }
            
            // INCREASED THRESHOLD: Check if agent reached shelter (was 10.0, now 200.0)
            if (dist < 200.0) {
                // Check if shelter has capacity
                if (closest_shelter.current_occupants < closest_shelter.capacity) {
                    is_safe <- true;
                    color <- #green;
                    closest_shelter.current_occupants <- closest_shelter.current_occupants + 1;
                    location <- closest_shelter.location;
                    
                    write "SUCCESS: Agent " + type + " reached shelter " + closest_shelter.name + " at cycle " + cycle;
                    
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
                } else {
                    // Shelter is full
                    if (cycle mod 100 = 0) {
                        write "WARNING: Shelter " + closest_shelter.name + " is FULL (" + 
                              closest_shelter.current_occupants + "/" + closest_shelter.capacity + ")";
                    }
                }
            }
        }
    }
    
    // CRITICAL: Enforce movement constraints (road/land only, no water)
    reflex enforce_constraints when: !is_dead and !is_safe {
        cell_grid current_cell <- cell_grid closest_to self;
        
        // CONSTRAINT 1: Check water constraint (highest priority)
        if (current_cell != nil and current_cell.is_water) {
            // Agent is in water - snap to nearest road immediately
            road nearest_road <- road closest_to self;
            if (nearest_road != nil) {
                location <- nearest_road.shape.points closest_to self;
                path_invalidated <- true;  // Force path recompute
            } else {
                // CRITICAL: No nearby road found - agent is isolated
                write "ERROR: Agent " + type + " isolated in water with no nearby roads at " + location;
                is_dead <- true;
                color <- #red;
                
                // Update death counters
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
        
        // CONSTRAINT 2: Ensure agent stays on road/land
        if (!is_dead and (current_cell = nil or (!current_cell.is_land and !current_cell.is_road))) {
            road r <- road closest_to self;
            if (r != nil) {
                location <- r.shape.points closest_to self;
                path_invalidated <- true;
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
                
                // SIMPLIFIED APPROACH: Use goto with simplified_road_network
                // GAMA automatically snaps location and target to graph vertices and finds path
                point target <- my_target_shelter.location;
                
                // Try simplified_road_network first (connected components)
                do goto target: target on: simplified_road_network speed: speed;
            }
            match "tourist" {
                // Add random speed variation for tourists, similar to locals and rescuers
                // This matches the NetLogo implementation where all agents have randomized speed
                speed <- gauss(speed, 1.0);
                if (speed < human_speed_min) { speed <- human_speed_min; }
                if (speed > human_speed_max) { speed <- human_speed_max; }
                
                if (tourist_strategy = "wandering") {
                    // NEW: Local Random Network Walk - OPTIMIZED VERSION
                    // Mimics NetLogo's 8-direction local movement but constrained to road network
                    
                    // Check if we've reached current target or need new target
                    bool need_new_target <- (current_target = nil) or 
                                            (location distance_to current_target < 10.0) or
                                            (cycles_since_path_update >= 8); // Optimized: longer interval to reduce computation
                    
                    if (need_new_target) {
                        // ERROR HANDLING: Ensure graph exists
                        if (simplified_road_network = nil) {
                            write "ERROR: " + name + " - simplified_road_network is nil!";
                            current_target <- my_target_shelter.location; // Fallback to shelter
                            cycles_since_path_update <- 0;
                        } else {
                            // 85% chance: Local movement (neighboring vertices)
                            // 15% chance: Exploration movement (distant vertex within 40m)
                            if (rnd(100) < 85) {
                                // LOCAL MOVEMENT: Get neighboring vertices (like NetLogo's adjacent patches)
                                list<point> neighboring_vertices <- get_neighboring_vertices();
                                
                                if (!empty(neighboring_vertices)) {
                                    // Select random neighboring vertex (mimics NetLogo's random direction choice)
                                    current_target <- one_of(neighboring_vertices);
                                    cycles_since_path_update <- 0;
                                } else {
                                    // Fallback: small radius exploration if no direct neighbors
                                    list<point> nearby_vertices <- simplified_road_network.vertices where (each distance_to self < 25.0);
                                    if (!empty(nearby_vertices)) {
                                        current_target <- one_of(nearby_vertices);
                                    } else {
                                        current_target <- my_target_shelter.location; // Last resort
                                        write "WARNING: " + name + " isolated, heading to shelter";
                                    }
                                    cycles_since_path_update <- 0;
                                }
                            } else {
                                // EXPLORATION MOVEMENT: Random vertex within moderate distance
                                list<point> exploration_vertices <- simplified_road_network.vertices where (each distance_to self < 40.0);
                                if (!empty(exploration_vertices)) {
                                    current_target <- one_of(exploration_vertices);
                                    cycles_since_path_update <- 0;
                                } else {
                                    // Fallback to local if no exploration targets
                                    list<point> neighboring_vertices <- get_neighboring_vertices();
                                    if (!empty(neighboring_vertices)) {
                                        current_target <- one_of(neighboring_vertices);
                                        cycles_since_path_update <- 0;
                                    }
                                }
                            }
                        }
                    }
                    
                    // Move toward current target if available
                    if (current_target != nil) {
                        point old_location <- copy(location);
                        do goto target: current_target on: simplified_road_network speed: speed;
                        float distance_moved <- old_location distance_to location;
                        
                        if (distance_moved < 0.01) {
                            // Force new target selection next cycle if stuck
                            cycles_since_path_update <- 999;
                        }
                    }
                } else if (tourist_strategy = "following rescuers or locals") {
                    // NETLOGO-INSPIRED: Following strategy with random wandering fallback
                    if (leader = nil or leader.is_dead or leader.is_safe) {
                        leader <- nil;
                        list<people> nearby_people <- get_nearby_people(radius_look);
                        list<people> potential_leaders <- nearby_people where (each.type = "rescuer");
                        if (empty(potential_leaders)) {
                            potential_leaders <- nearby_people where (each.type = "local");
                        }
                        if (!empty(potential_leaders)) {
                            leader <- one_of(potential_leaders);  // Random leader selection
                        }
                    }
                    
                    if (leader != nil) {
                        // Follow leader using goto
                        point old_location <- copy(location);
                        do goto target: leader.location on: simplified_road_network speed: speed;
                        float distance_moved <- old_location distance_to location;
                        
                        // Check if leader is still valid
                        if (leader.is_dead or leader.is_safe) {
                            leader <- nil;
                        }
                    } else {
                        // NETLOGO MATCH: No leader - use LOCAL RANDOM WANDERING (NOT shortest path to shelter!)
                        // NetLogo checks 8 directions and picks the first valid one - this is random exploration
                        bool need_new_target <- (current_target = nil) or 
                                                (location distance_to current_target < 10.0) or
                                                (cycles_since_path_update >= 8);
                        
                        if (need_new_target) {
                            if (rnd(100) < 85) {
                                // LOCAL MOVEMENT: neighboring vertices
                                list<point> neighboring_vertices <- get_neighboring_vertices();
                                if (!empty(neighboring_vertices)) {
                                    current_target <- one_of(neighboring_vertices);
                                    cycles_since_path_update <- 0;
                                } else {
                                    // Fallback
                                    list<point> nearby_vertices <- simplified_road_network.vertices where (each distance_to self < 25.0);
                                    if (!empty(nearby_vertices)) {
                                        current_target <- one_of(nearby_vertices);
                                    } else {
                                        current_target <- my_target_shelter.location;
                                    }
                                    cycles_since_path_update <- 0;
                                }
                            } else {
                                // EXPLORATION: moderate distance
                                list<point> exploration_vertices <- simplified_road_network.vertices where (each distance_to self < 40.0);
                                if (!empty(exploration_vertices)) {
                                    current_target <- one_of(exploration_vertices);
                                    cycles_since_path_update <- 0;
                                } else {
                                    // Fallback to local
                                    list<point> neighboring_vertices <- get_neighboring_vertices();
                                    if (!empty(neighboring_vertices)) {
                                        current_target <- one_of(neighboring_vertices);
                                        cycles_since_path_update <- 0;
                                    }
                                }
                            }
                        }
                        
                        // Move toward current target
                        if (current_target != nil) {
                            point old_location <- copy(location);
                            do goto target: current_target on: simplified_road_network speed: speed;
                            float distance_moved <- old_location distance_to location;
                            
                            if (distance_moved < 0.01) {
                                // Force new target if stuck
                                cycles_since_path_update <- 999;
                            }
                        }
                    }
                } else if (tourist_strategy = "following crowd") {
                    // NETLOGO-INSPIRED: Directional crowd scanning (mimics NetLogo's 8-direction check)
                    // NetLogo checks 8 directions (0°, 45°, 90°, 135°, 180°, 225°, 270°, 315°)
                    // and finds the direction with the MOST people within centroid_radius
                    
                    float centroid_distance <- radius_look / 2.0;  // Distance to scan in each direction
                    float centroid_radius <- radius_look / 2.0;    // Radius to count people at each scan point
                    int max_crowd_size <- 0;
                    point best_scan_point <- nil;
                    
                    // DIRECTIONAL SCANNING: Check 8 directions like NetLogo
                    list<int> angles <- [0, 45, 90, 135, 180, 225, 270, 315];
                    loop angle over: angles {
                        // Calculate scan point in this direction
                        float angle_rad <- angle * #pi / 180.0;
                        float scan_x <- location.x + centroid_distance * cos(angle_rad);
                        float scan_y <- location.y + centroid_distance * sin(angle_rad);
                        point scan_point <- {scan_x, scan_y};
                        
                        // Count people (tourists + locals) within centroid_radius of scan point
                        list<people> crowd_at_point <- get_nearby_people(radius_look) where (
                            (each.type = "tourist" or each.type = "local") and
                            (each.location distance_to scan_point) <= centroid_radius
                        );
                        
                        int crowd_count <- length(crowd_at_point);
                        
                        // Track direction with maximum crowd
                        if (crowd_count > max_crowd_size) {
                            max_crowd_size <- crowd_count;
                            best_scan_point <- scan_point;
                        }
                    }
                    
                    // Move toward densest crowd direction
                    if (best_scan_point != nil and max_crowd_size > 0) {
                        // Use local network walk toward crowd direction
                        list<point> neighboring_vertices <- get_neighboring_vertices();
                        
                        if (!empty(neighboring_vertices)) {
                            // Select neighbor closest to best crowd direction
                            point best_neighbor <- neighboring_vertices with_min_of (each distance_to best_scan_point);
                            point old_location <- copy(location);
                            do goto target: best_neighbor on: simplified_road_network speed: speed;
                            float distance_moved <- old_location distance_to location;
                            
                            if (distance_moved < 0.01) {
                                // Stuck - try random neighbor instead
                                current_target <- one_of(neighboring_vertices);
                                do goto target: current_target on: simplified_road_network speed: speed;
                            }
                        } else {
                            // No neighbors - fallback to moderate distance exploration
                            list<point> nearby_vertices <- simplified_road_network.vertices where (each distance_to self < 30.0);
                            if (!empty(nearby_vertices)) {
                                point best_nearby <- nearby_vertices with_min_of (each distance_to best_scan_point);
                                do goto target: best_nearby on: simplified_road_network speed: speed;
                            }
                        }
                    } else {
                        // No crowd found - use local wandering (same as wandering strategy)
                        bool need_new_target <- (current_target = nil) or 
                                                (location distance_to current_target < 10.0) or
                                                (cycles_since_path_update >= 8);
                        
                        if (need_new_target) {
                            if (rnd(100) < 85) {
                                list<point> neighboring_vertices <- get_neighboring_vertices();
                                if (!empty(neighboring_vertices)) {
                                    current_target <- one_of(neighboring_vertices);
                                    cycles_since_path_update <- 0;
                                }
                            } else {
                                list<point> exploration_vertices <- simplified_road_network.vertices where (each distance_to self < 40.0);
                                if (!empty(exploration_vertices)) {
                                    current_target <- one_of(exploration_vertices);
                                    cycles_since_path_update <- 0;
                                }
                            }
                        }
                        
                        if (current_target != nil) {
                            do goto target: current_target on: simplified_road_network speed: speed;
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
                    // SIMPLIFIED: Force evacuation using goto
                    point target <- my_target_shelter.location;
                    do goto target: target on: simplified_road_network speed: (speed * 1.5);
                } else {
                    // RESCUE OPERATIONS
                    list<people> nearby_tourists <- get_nearby_people(radius_look) where (each.type = "tourist" and !each.is_safe and !each.is_dead);
                    
                    if (!empty(nearby_tourists)) {
                        // Lead tourists to shelter using goto
                        point target <- my_target_shelter.location;
                        do goto target: target on: simplified_road_network speed: speed;
                    } else {
                        // IMPROVED: Local random network walk (same as tourist wandering)
                        bool need_new_target <- (current_target = nil) or 
                                                (location distance_to current_target < 10.0) or
                                                (cycles_since_path_update >= 8);
                        
                        if (need_new_target) {
                            if (simplified_road_network = nil) {
                                current_target <- my_target_shelter.location;
                                cycles_since_path_update <- 0;
                            } else {
                                // 85% local movement, 15% exploration
                                if (rnd(100) < 85) {
                                    // LOCAL MOVEMENT
                                    list<point> neighboring_vertices <- get_neighboring_vertices();
                                    if (!empty(neighboring_vertices)) {
                                        current_target <- one_of(neighboring_vertices);
                                        cycles_since_path_update <- 0;
                                    } else {
                                        // Fallback
                                        list<point> nearby_vertices <- simplified_road_network.vertices where (each distance_to self < 25.0);
                                        if (!empty(nearby_vertices)) {
                                            current_target <- one_of(nearby_vertices);
                                        } else {
                                            current_target <- my_target_shelter.location;
                                        }
                                        cycles_since_path_update <- 0;
                                    }
                                } else {
                                    // EXPLORATION
                                    list<point> exploration_vertices <- simplified_road_network.vertices where (each distance_to self < 40.0);
                                    if (!empty(exploration_vertices)) {
                                        current_target <- one_of(exploration_vertices);
                                        cycles_since_path_update <- 0;
                                    } else {
                                        // Fallback to local
                                        list<point> neighboring_vertices <- get_neighboring_vertices();
                                        if (!empty(neighboring_vertices)) {
                                            current_target <- one_of(neighboring_vertices);
                                            cycles_since_path_update <- 0;
                                        }
                                    }
                                }
                            }
                        }
                        
                        // Move toward current target
                        if (current_target != nil) {
                            point old_location <- copy(location);
                            do goto target: current_target on: simplified_road_network speed: speed;
                            float distance_moved <- old_location distance_to location;
                            
                            if (distance_moved < 0.01) {
                                // Force new target selection if stuck
                                cycles_since_path_update <- 999;
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
    
    // POSITION LOGGING
    point initial_position;
    bool position_logged <- false;
    
    // OPTIMIZATION: Precomputed target shelter and vertex
    shelter my_target_shelter;
    point my_target_vertex;
    
    // OPTIMIZATION: Path caching for cars
    path current_path;
    point current_target;
    int path_recompute_interval <- 15;  // Cars recompute less often
    int cycles_since_path_update <- 0;
    bool path_invalidated <- false;
    int path_validity_counter <- 0;
    
    // OPTIMIZATION: Multi-level pathfinding for cars (same strategy as people)
    action get_car_path_to(point target) type: path {
        // CRITICAL: Check if target is nil to prevent NullPointerException
        if (target = nil) {
            return nil;
        }
        
        bool need_recompute <- (current_path = nil) or 
                               (current_target = nil) or
                               (current_target distance_to target > 10.0) or
                               (path_validity_counter >= 15) or
                               path_invalidated;
        
        if (need_recompute) {
            path new_path <- nil;
            
            // CRITICAL FIX: Try simplified_road_network FIRST (guaranteed connected)
            point start_vertex_simp <- simplified_road_network.vertices with_min_of (each distance_to location);
            point target_vertex_simp <- simplified_road_network.vertices with_min_of (each distance_to target);
            
            // LEVEL 1: Try simplified_road_network FIRST (connected components)
            if (start_vertex_simp != nil and target_vertex_simp != nil) {
                new_path <- path_between(simplified_road_network, start_vertex_simp, target_vertex_simp);
            }
            
            // LEVEL 2: Fallback to FULL road_network if simplified fails
            if (new_path = nil or empty(new_path.edges)) {
                point start_vertex_full <- road_network.vertices with_min_of (each distance_to location);
                point target_vertex_full <- road_network.vertices with_min_of (each distance_to target);
                
                if (start_vertex_full != nil and target_vertex_full != nil) {
                    new_path <- path_between(road_network, start_vertex_full, target_vertex_full);
                }
            }
            
            // Update cache
            current_path <- new_path;
            current_target <- target;
            path_validity_counter <- 0;
            path_invalidated <- false;
            cycles_since_path_update <- 0;
            return new_path;
        } else {
            // Use cached path
            path_validity_counter <- path_validity_counter + 1;
            cycles_since_path_update <- cycles_since_path_update + 1;
            return current_path;
        }
    }
    
    // OPTIMIZATION: Get nearby cars/people using spatial index
    list<car> get_nearby_cars(float distance) {
        cell_grid my_cell <- cell_grid closest_to self;
        list<car> nearby <- [];
        
        if (my_cell != nil and (car_spatial_index.keys contains my_cell)) {
            nearby <- car_spatial_index[my_cell];
            ask my_cell.neighbors {
                if (car_spatial_index.keys contains self) {
                    nearby <- nearby + car_spatial_index[self];
                }
            }
            // Filter by actual distance - store reference to avoid 'myself' issue
            car current_car <- self;
            nearby <- nearby where (each != current_car and (each.location distance_to current_car.location) <= distance);
        }
        
        return nearby;
    }
    
    // Helper for getting nearby people
    list<people> get_nearby_people(float distance) {
        cell_grid my_cell <- cell_grid closest_to self;
        list<people> nearby <- [];
        
        if (my_cell != nil and (people_spatial_index.keys contains my_cell)) {
            nearby <- people_spatial_index[my_cell];
            ask my_cell.neighbors {
                if (people_spatial_index.keys contains self) {
                    nearby <- nearby + people_spatial_index[self];
                }
            }
            // Filter by actual distance - store reference to avoid 'myself' issue
            car current_car <- self;
            nearby <- nearby where ((each.location distance_to current_car.location) <= distance);
        }
        
        return nearby;
    }
    
    aspect default {
        draw car_icon size: {150,100} rotate: heading at: location;  // Much larger size
    }
    
    reflex check_safety when: !is_dead and !is_safe {
        shelter closest_shelter <- shelter closest_to self;
        
        if (closest_shelter != nil) {
            float dist <- self distance_to closest_shelter;
            
            // DEBUG: Log when cars get close to shelters
            if (dist < 150.0 and cycle mod 50 = 0) {
                write "Car at distance " + dist + " from shelter " + closest_shelter.name + 
                      " (capacity: " + closest_shelter.current_occupants + "/" + closest_shelter.capacity + ")";
            }
            
            // INCREASED THRESHOLD: Check if car reached shelter (was 10.0, now 200.0)
            if (dist < 200.0) {
                // Check if shelter has capacity for all people in car
                if (closest_shelter.current_occupants + nb_people_in <= closest_shelter.capacity) {
                    is_safe <- true;
                    color <- #green;
                    closest_shelter.current_occupants <- closest_shelter.current_occupants + nb_people_in;
                    location <- closest_shelter.location;
                    cars_safe <- cars_safe + 1;
                    cars_in_danger <- cars_in_danger - 1;
                    
                    write "SUCCESS: Car with " + nb_people_in + " people reached shelter " + closest_shelter.name + " at cycle " + cycle;
                } else {
                    // Shelter doesn't have enough capacity
                    if (cycle mod 100 = 0) {
                        write "WARNING: Shelter " + closest_shelter.name + " doesn't have capacity for car (" + 
                              closest_shelter.current_occupants + "+" + nb_people_in + "/" + closest_shelter.capacity + ")";
                    }
                }
            }
        }
    }
    
    // CRITICAL: Enforce movement constraints for cars (road/land only, no water)
    reflex enforce_constraints when: !is_dead and !is_safe {
        cell_grid current_cell <- cell_grid closest_to self;
        
        // CONSTRAINT 1: Check water constraint
        if (current_cell != nil and current_cell.is_water) {
            // Car is in water - snap to nearest road
            road nearest_road <- road closest_to self;
            if (nearest_road != nil) {
                location <- nearest_road.shape.points closest_to self;
                path_invalidated <- true;
            } else {
                // Car is isolated - abandon car and create people
                create people number: nb_people_in {
                    type <- "local";
                    location <- myself.location;
                    color <- #yellow;
                    is_dead <- false;
                    is_safe <- false;
                    speed <- rnd(human_speed_min, human_speed_max);
                    agent_size <- locals_size;
                    
                    // Precompute target for new people
                    shelter nearest_shelter <- shelter with_min_of (each distance_to self);
                    my_target_shelter <- nearest_shelter;
                    my_target_vertex <- nearest_shelter.target_vertex;
                }
                cars_in_danger <- cars_in_danger - 1;
                locals_in_danger <- locals_in_danger + nb_people_in;
                do die;
            }
        }
        
        // CONSTRAINT 2: Ensure car stays on road (only if significantly off-road)
        if (!is_dead) {
            road r <- road closest_to self;
            if (r != nil) {
                point rp <- r.shape.points closest_to self;
                float distance_to_road <- location distance_to rp;
                
                // CRITICAL FIX: Only snap if car is MORE THAN 50m off road
                // This prevents constantly snapping back and blocking movement
                if (distance_to_road > 50.0) {
                    write "[CAR CONSTRAINT] " + name + " is " + distance_to_road + "m off road, snapping back";
                    location <- rp;
                    path_invalidated <- true;
                }
            }
        }
    }

    reflex move when: !is_dead and !is_safe and (cycle mod update_frequency = 0) {
        // LOG INITIAL POSITION (only once)
        if (!position_logged) {
            initial_position <- copy(location);
            position_logged <- true;
        }
        
        // Strategy 1: Always go ahead
        if (car_strategy = "always go ahead") {
            // SIMPLIFIED: Use goto với simplified_road_network
            point target <- my_target_shelter.location;
            
            // Check for obstacles ahead
            list<people> people_ahead <- get_nearby_people(5.0);
            list<car> cars_ahead <- get_nearby_cars(5.0);
            
            if (!empty(people_ahead) or !empty(cars_ahead)) {
                // Path is blocked, decelerate
                speed <- max([speed - car_deceleration, car_speed_min]);
            } else {
                // Path is clear, accelerate
                speed <- min([speed + car_acceleration, car_speed_max]);
            }
            
            // Move using goto
            do goto target: target on: simplified_road_network speed: speed;
        }
        // Strategy: Go out when congestion
        else if (car_strategy = "go out when congestion") {
            // SIMPLIFIED: Use goto with simplified_road_network
            point target <- my_target_shelter.location;
            road current_road <- road closest_to self;
            
            // Check if current road is flooded
            if (current_road != nil and current_road.is_flooded) {
                write "[CAR ABANDONED] " + name + " (flooded) - creating " + nb_people_in + " people";
                // Create people from car occupants
                create people number: nb_people_in {
                    type <- "local";
                    location <- myself.location;
                    color <- #yellow;
                    is_dead <- false;
                    is_safe <- false;
                    speed <- rnd(human_speed_min, human_speed_max);
                    agent_size <- locals_size;
                }
                cars_in_danger <- cars_in_danger - 1;
                locals_in_danger <- locals_in_danger + nb_people_in;
                do die;
            } else {
                // OPTIMIZED: Use spatial index for congestion check
                list<people> people_ahead <- get_nearby_people(5.0);
                list<car> cars_ahead <- get_nearby_cars(5.0);
                
                if (!empty(people_ahead) or !empty(cars_ahead)) {
                    cars_time_wait <- cars_time_wait + 1;
                    speed <- max([speed - car_deceleration, car_speed_min]);
                    path_invalidated <- true;
                    
                    if (cars_time_wait >= cars_threshold_wait) {
                        write "[CAR ABANDONED] " + name + " (timeout) - creating " + nb_people_in + " people";
                        // Abandon car and create people
                        create people number: nb_people_in {
                            type <- "local";
                            location <- myself.location;
                            color <- #yellow;
                            is_dead <- false;
                            is_safe <- false;
                            speed <- rnd(human_speed_min, human_speed_max);
                            agent_size <- locals_size;
                        }
                        cars_in_danger <- cars_in_danger - 1;
                        locals_in_danger <- locals_in_danger + nb_people_in;
                        do die;
                    }
                    
                    // Still try to move even when congested
                    do goto target: target on: simplified_road_network speed: speed;
                } else {
                    // Path is clear
                    cars_time_wait <- 0;
                    speed <- min([speed + car_acceleration, car_speed_max]);
                    // Move using goto
                    do goto target: target on: simplified_road_network speed: speed;
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
    parameter "Agent update frequency" var: update_frequency min: 1 max: 10;
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