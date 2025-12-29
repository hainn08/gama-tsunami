# Mô Hình Mô Phỏng Sơ Tán Tsunami - Báo Cáo Kỹ Thuật

## Tổng Quan

Mô hình này mô phỏng quá trình sơ tán dân cư khi có sóng thần xảy ra, sử dụng nền tảng GAMA Platform. Mô hình bao gồm các thành phần chính: hệ thống đường giao thông (road network), các loại agents (người dân, du khách, lực lượng cứu hộ, xe ô tô), và mô phỏng sóng thần.

---

## 1. Cách Đi Của Các Loại Agents

### 1.1. Người Dân Địa Phương (Locals)

**Chiến lược di chuyển:**
- **Mục tiêu:** Di chuyển trực tiếp đến nơi trú ẩn gần nhất
- **Phương pháp:** Sử dụng thuật toán pathfinding `goto` trên mạng lưới đường đã được tối ưu hóa (`simplified_road_network`)
- **Tốc độ:**
  - Tốc độ trung bình: 4.2 m/s
  - Tốc độ tối thiểu: 1.4 m/s
  - Tốc độ tối đa: 7.0 m/s
  - Phân phối: Gaussian với độ lệch chuẩn 0.3
  - Tốc độ được randomize mỗi bước để mô phỏng tính thực tế

**Cơ chế:**
```gaml
// Locals sử dụng goto trực tiếp đến shelter
point target <- my_target_shelter.location;
do goto target: target on: simplified_road_network speed: speed;
```

**Ràng buộc:**
- Chỉ di chuyển trên đường và đất liền (không đi trên nước)
- Tự động snap về đường gần nhất nếu lệch khỏi đường
- Dừng di chuyển khi đến nơi trú ẩn hoặc bị sóng thần cuốn

---

### 1.2. Du Khách (Tourists)

Du khách có 3 chiến lược di chuyển khác nhau:

#### A. Wandering (Lang Thang Ngẫu Nhiên)

**Mô tả:** Du khách di chuyển ngẫu nhiên trên mạng lưới đường, không có mục tiêu cụ thể.

**Cơ chế:**
- **85% thời gian:** Di chuyển đến đỉnh lân cận (neighboring vertices) - mô phỏng chuyển động địa phương
- **15% thời gian:** Khám phá đỉnh xa hơn trong bán kính 40m - mô phỏng khám phá

**Thuật toán:**
```gaml
// Lấy các đỉnh lân cận trên đồ thị
list<point> neighboring_vertices <- get_neighboring_vertices();

// Chọn ngẫu nhiên một đỉnh lân cận
current_target <- one_of(neighboring_vertices);

// Di chuyển đến đỉnh đó
do goto target: current_target on: simplified_road_network speed: speed;
```

**Cập nhật mục tiêu:**
- Khi đạt đến mục tiêu hiện tại (khoảng cách < 10m)
- Sau mỗi 8 chu kỳ để tránh bị kẹt

#### B. Following Rescuers or Locals (Theo Dõi Lực Lượng Cứu Hộ hoặc Người Dân)

**Mô tả:** Du khách tìm và theo dõi lực lượng cứu hộ hoặc người dân địa phương để được hướng dẫn.

**Cơ chế:**
1. **Tìm leader:**
   - Ưu tiên tìm lực lượng cứu hộ trong bán kính `radius_look`
   - Nếu không có, tìm người dân địa phương
   - Chọn ngẫu nhiên một leader từ danh sách

2. **Theo dõi leader:**
   ```gaml
   if (leader != nil) {
       do goto target: leader.location on: simplified_road_network speed: speed;
   }
   ```

3. **Fallback:** Nếu không tìm thấy leader, chuyển sang chế độ wandering

**Cập nhật leader:**
- Tìm lại leader mỗi khi leader chết hoặc đã an toàn
- Tự động bỏ leader nếu leader không còn hợp lệ

#### C. Following Crowd (Theo Đám Đông)

**Mô tả:** Du khách quét 8 hướng (0°, 45°, 90°, 135°, 180°, 225°, 270°, 315°) để tìm hướng có nhiều người nhất, sau đó di chuyển về hướng đó.

**Cơ chế:**
1. **Quét 8 hướng:**
   ```gaml
   list<int> angles <- [0, 45, 90, 135, 180, 225, 270, 315];
   loop angle over: angles {
       // Tính điểm quét trong hướng này
       float angle_rad <- angle * #pi / 180.0;
       point scan_point <- {location.x + centroid_distance * cos(angle_rad), 
                           location.y + centroid_distance * sin(angle_rad)};
       
       // Đếm số người trong bán kính centroid_radius
       int crowd_count <- length(crowd_at_point);
   }
   ```

2. **Chọn hướng đông nhất:**
   - Chọn hướng có `max_crowd_size`
   - Di chuyển đến đỉnh lân cận gần nhất với hướng đó

3. **Fallback:** Nếu không tìm thấy đám đông, chuyển sang wandering

**Tốc độ:** Giống như locals (Gaussian, 1.4-7.0 m/s)

---

### 1.3. Lực Lượng Cứu Hộ (Rescuers)

**Chiến lược kép:**

#### A. Hoạt Động Cứu Hộ

**Điều kiện:** Khi không có nguy hiểm trực tiếp từ sóng thần

**Cơ chế:**
1. **Tìm du khách cần cứu:**
   ```gaml
   list<people> nearby_tourists <- get_nearby_people(radius_look) 
       where (each.type = "tourist" and !each.is_safe and !each.is_dead);
   ```

2. **Dẫn dắt đến nơi trú ẩn:**
   - Nếu tìm thấy du khách, di chuyển đến nơi trú ẩn để dẫn dắt họ
   - Sử dụng `goto` với tốc độ bình thường

3. **Tìm kiếm:** Nếu không có du khách gần đó, di chuyển ngẫu nhiên (giống wandering) để tìm kiếm

#### B. Sơ Tán Khẩn Cấp

**Điều kiện:** 
- Khoảng cách đến sóng thần < 150m
- Hoặc đang ở trong vùng ngập lụt

**Cơ chế:**
```gaml
if (immediate_danger or min_tsunami_distance < 150.0) {
    // Sơ tán với tốc độ nhanh hơn 50%
    do goto target: my_target_shelter.location 
        on: simplified_road_network 
        speed: (speed * 1.5);
}
```

**Tốc độ:** Giống như locals, nhưng tăng 50% khi sơ tán khẩn cấp

---

### 1.4. Xe Ô Tô (Cars)

Xe ô tô có 2 chiến lược di chuyển:

#### A. Always Go Ahead (Luôn Tiến Lên)

**Mô tả:** Xe luôn cố gắng di chuyển đến nơi trú ẩn, bất kể tình trạng giao thông.

**Cơ chế:**
1. **Pathfinding:**
   ```gaml
   point target <- my_target_shelter.location;
   do goto target: target on: simplified_road_network speed: speed;
   ```

2. **Phát hiện kẹt xe:**
   - Kiểm tra nếu xe di chuyển < 0.5m trong 3 chu kỳ liên tiếp
   - Nếu kẹt, vô hiệu hóa đường đi và thử tìm đỉnh thay thế

3. **Kiểm tra chướng ngại vật phía trước:**
   ```gaml
   bool has_agents_ahead <- check_agents_ahead(target, check_distance);
   ```
   - Quét trong góc 90° phía trước (sử dụng dot product)
   - Nếu có agents (xe hoặc người) trong 5m phía trước → dừng lại (tốc độ = 10% min speed)
   - Nếu không có → tăng tốc và di chuyển

4. **Xử lý kẹt xe:**
   - Thử di chuyển đến đỉnh lân cận
   - Nếu đỉnh hiện tại bị cô lập, tìm đỉnh thay thế trong bán kính 100m
   - Fallback: sử dụng `road_network` đầy đủ nếu `simplified_road_network` không khả dụng

**Tốc độ:**
- Tốc độ trung bình: 18.75 m/s
- Tốc độ tối thiểu: 1.4 m/s
- Tốc độ tối đa: 36.1 m/s
- Phân phối: Gaussian với độ lệch chuẩn 0.5
- Gia tốc: `car_acceleration` mỗi chu kỳ khi đường thông thoáng

#### B. Go Out When Congestion (Bỏ Xe Khi Kẹt Xe)

**Mô tả:** Xe sẽ bỏ lại và chuyển hành khách thành người đi bộ nếu kẹt xe quá lâu.

**Cơ chế:**
1. **Kiểm tra ngập lụt:**
   ```gaml
   if (current_road.is_flooded) {
       // Tạo người đi bộ từ hành khách
       create people number: nb_people_in;
       do die; // Xe bị hủy
   }
   ```

2. **Kiểm tra kẹt xe:**
   - Sử dụng `check_agents_ahead` để phát hiện chướng ngại vật
   - Nếu kẹt, tăng `cars_time_wait`
   - Nếu `cars_time_wait >= cars_threshold_wait` → bỏ xe

3. **Bỏ xe:**
   ```gaml
   create people number: nb_people_in {
       type <- "local";
       location <- myself.location;
       // Khởi tạo như người đi bộ bình thường
   }
   do die; // Xe bị hủy
   ```

**Ràng buộc:**
- Chỉ di chuyển trên đường và đất liền
- Tự động snap về đường nếu lệch
- Nếu rơi vào nước → bỏ xe ngay lập tức

---

## 2. Cách Đi Của Sóng Thần (Tsunami Wave)

### 2.1. Mô Hình Sóng Thần

Sóng thần được mô phỏng như một bức tường nước di chuyển từ biển vào đất liền, được chia thành nhiều đoạn (`tsunami_nb_segments`) để xử lý địa hình phức tạp.

### 2.2. Tốc Độ Di Chuyển

**Trong đại dương:**
- Tốc độ cố định: **44.3 m/s** (không có randomness)
- Được tính từ công thức: `sqrt(200 * 9.8)` cho vùng nước nông
- Tốc độ được scale theo `scale_factor` và chuyển đổi đơn vị (m/s → pixels/step)

**Trên đất liền:**
- Tốc độ giảm dần khi sóng tiến vào đất liền
- Mỗi chu kỳ giảm: **5-15 m/s** (random)
- Dừng lại khi tốc độ ≤ 0

**Cơ chế:**
```gaml
if (segment_coord >= coastal_x) {
    // Vẫn trong đại dương - duy trì tốc độ cố định
    tsunami_current_speed[i] <- tsunami_speed_avg;
} else {
    // Đã đến bờ - giảm tốc độ dần dần
    segment_speed <- segment_speed - rnd(5.0, 15.0);
    if (segment_speed < 0) {
        segment_speed <- 0.0;
    }
}
```

### 2.3. Cập Nhật Vị Trí

Mỗi chu kỳ, mỗi đoạn sóng di chuyển:
```gaml
float tsunami_speed_scale <- segment_speed * scale_factor * 60.0 / 3.6;
tsunami_curr_coord[i] <- segment_coord - tsunami_speed_scale * step;
```

**Lưu ý:** Sóng di chuyển từ phải sang trái (giảm tọa độ x)

### 2.4. Logic Ngập Lụt

#### A. Trong Đại Dương
- **Xác suất ngập:** 100% (đảm bảo)
- **Cường độ ngập:** Tăng nhanh (70% cơ hội tăng 0.2 mỗi chu kỳ)
- **Màu sắc:** Xanh dương đậm (`rgb(0, 0, 255)`)

#### B. Trên Đất Liền
- **Xác suất ngập:** 50% (probabilistic)
- **Cường độ ngập:** Tăng chậm (40% cơ hội tăng 0.1 mỗi chu kỳ)
- **Màu sắc:** Xanh dương nhạt (`rgb(0, 100, 255, 0.7)`)
- **Ngoại lệ:** Nơi trú ẩn (`shelter_id != -1`) không bị ngập

#### C. Đảm Bảo Ngập Lụt Phía Sau
```gaml
// Đảm bảo các ô cách mặt sóng > 50m đều bị ngập
if (tsunami_curr_coord[i] - location.x > 50.0) {
    is_flooded <- true;
}
```

### 2.5. Ngập Lụt Đường Xá

Đường xá có xác suất ngập cao hơn (70% thay vì 50%):
```gaml
if (!is_flooded and rnd(10) < 7) {
    is_flooded <- true;
    color <- rgb(0, 0, 255, 0.8);
}
```

### 2.6. Tác Động Lên Agents

**Người đi bộ:**
- Nếu ở trong ô bị ngập (`current_cell.is_flooded`) → chết
- Kiểm tra mỗi chu kỳ trong `reflex check_safety`

**Xe ô tô:**
- Nếu đường bị ngập (`current_road.is_flooded`) → bỏ xe, chuyển hành khách thành người đi bộ

---

## 3. Cách Tạo Road Network

### 3.1. Tổng Quan

Road Network được xây dựng từ dữ liệu GIS (shapefile) và được tối ưu hóa để đảm bảo tính kết nối và hiệu suất pathfinding.

### 3.2. Quy Trình Xây Dựng

#### Bước 1: Đọc Dữ Liệu GIS
```gaml
create road from: road_shapefile;
```
- Đọc file shapefile chứa các đoạn đường
- Mỗi đoạn đường là một `geometry` (thường là `polyline`)

#### Bước 2: Làm Sạch Mạng Lưới (Clean Network)

**Mục đích:** 
- Tách các đường tại điểm giao nhau
- Gộp các đỉnh gần nhau (trong tolerance)
- Loại bỏ trùng lặp

**Thực hiện:**
```gaml
list<geometry> cleaned_roads <- clean_network(
    road collect each.shape,        // Input: tất cả các geometry đường
    road_connection_tolerance,      // Tolerance: 10.0m (gộp đỉnh trong 10m)
    true,                            // split_lines: TÁCH tại điểm giao nhau
    false                            // keepMainConnectedComponent: giữ tất cả components
);
```

**Tham số:**
- `road_connection_tolerance = 10.0m`: Các đỉnh cách nhau < 10m sẽ được gộp lại
- `split_lines = true`: **QUAN TRỌNG** - Tách đường tại tất cả điểm giao nhau
- `keepMainConnectedComponent = false`: Giữ tất cả các thành phần kết nối

**Kết quả:**
- Số lượng đường tăng lên (do tách tại giao lộ)
- Các đỉnh gần nhau được gộp lại
- Đảm bảo tính kết nối tại các nút giao thông

#### Bước 3: Tạo Đồ Thị Tạm Thời

```gaml
graph temp_graph <- as_edge_graph(road);
```

**Mục đích:** 
- Phân tích tính kết nối của mạng lưới
- Tìm các thành phần kết nối (connected components)

**Lưu ý:** Đồ thị này chỉ dùng để phân tích, không có trọng số

#### Bước 4: Phân Tích Thành Phần Kết Nối

```gaml
list<list> components <- connected_components_of(temp_graph);
```

**Mục đích:**
- Tìm tất cả các thành phần kết nối trong mạng lưới
- Mỗi thành phần là một tập hợp các đỉnh có thể đến được lẫn nhau

**Ví dụ:**
- Component 1: 5000 đỉnh (mạng lưới chính)
- Component 2: 50 đỉnh (đường phụ)
- Component 3: 10 đỉnh (đường cô lập)

#### Bước 5: Lọc Thành Phần Nhỏ

```gaml
list<list> major_components <- components 
    where (length(each) >= min_component_size);
```

**Mục đích:**
- Loại bỏ các thành phần quá nhỏ (đường cô lập, đường phụ không quan trọng)
- `min_component_size` (mặc định: 50 đỉnh) - chỉ giữ các thành phần có ≥ 50 đỉnh

**Lợi ích:**
- Giảm số lượng đỉnh và cạnh trong đồ thị
- Tăng hiệu suất pathfinding
- Loại bỏ các đường không thể sử dụng để sơ tán

#### Bước 6: Lọc Đường Theo Thành Phần

```gaml
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
```

**Mục đích:**
- Chỉ giữ lại các đường có ít nhất một điểm thuộc thành phần lớn
- Loại bỏ các đường cô lập

#### Bước 7: Tạo Đồ Thị Cuối Cùng

**A. Road Network (Đồ thị đầy đủ):**
```gaml
road_network <- as_edge_graph(connected_roads);
```
- Đồ thị không có trọng số
- Dùng làm fallback khi `simplified_road_network` không khả dụng

**B. Simplified Road Network (Đồ thị có trọng số):**
```gaml
map<road, float> road_weights <- connected_roads 
    as_map (each::each.shape.perimeter);
simplified_road_network <- as_edge_graph(connected_roads) 
    with_weights road_weights;
```

**Trọng số:**
- Mỗi cạnh có trọng số = chu vi của đoạn đường (`shape.perimeter`)
- Đường dài hơn → trọng số lớn hơn → pathfinding sẽ ưu tiên đường ngắn hơn

**Sử dụng:**
- `simplified_road_network` là đồ thị chính cho pathfinding
- Agents sử dụng `goto` trên đồ thị này để tìm đường ngắn nhất

### 3.3. Tối Ưu Hóa

#### A. Tạo Đồ Thị Một Lần
- Trước đây: Tạo đồ thị 2 lần (một lần để phân tích, một lần để sử dụng)
- Hiện tại: Tạo đồ thị tạm thời để phân tích, sau đó tạo đồ thị cuối cùng một lần

#### B. Lọc Thành Phần Không Điều Kiện
- Trước đây: Chỉ lọc khi có nhiều hơn 1 component
- Hiện tại: Luôn lọc theo `min_component_size` để đảm bảo tính nhất quán

#### C. Lưu Trữ Đỉnh Cho Visualization
```gaml
network_vertices <- temp_graph.vertices;
```
- Lưu danh sách đỉnh để hiển thị (có thể bật/tắt bằng parameter)

### 3.4. Kết Quả

**Trước khi tối ưu:**
- Số thành phần kết nối: ~2100 (quá nhiều, không thực tế)
- Hiệu suất pathfinding: Chậm do quá nhiều đỉnh/cạnh

**Sau khi tối ưu:**
- Số thành phần kết nối: < 100 (chỉ giữ các thành phần lớn)
- Hiệu suất pathfinding: Nhanh hơn đáng kể
- Đảm bảo tính kết nối tại các nút giao thông

### 3.5. Validation

**Kiểm tra:**
- Số lượng đỉnh và cạnh trong đồ thị cuối cùng
- Số lượng thành phần kết nối
- Cảnh báo nếu số lượng đường quá cao (> 15000) có thể ảnh hưởng hiệu suất

**Logging:**
```
Building road network...
Original roads count: 5000
Cleaning road network topology...
Network cleaned in 250ms
Cleaned geometries count: 7500
Analyzing network connectivity...
Number of disconnected road components: 85
Filtering: Using 12 major components (size >= 50 nodes)
Final graph has 4500 vertices and 6000 edges
```

---

## 4. Các Tính Năng Bổ Sung

### 4.1. Hiển Thị Đỉnh Mạng Lưới

- **Parameter:** `show_network_vertices` (checkbox)
- **Kích thước:** `vertex_display_size` (1.0 - 20.0)
- **Màu sắc:** Đỏ với viền đỏ đậm
- **Mục đích:** Debug và kiểm tra tính kết nối của mạng lưới

### 4.2. Logging Thời Gian Mô Phỏng

- **Thời điểm bắt đầu:** Ghi lại khi khởi tạo xong
- **Thời điểm kết thúc:** Ghi lại khi tất cả agents đã an toàn hoặc chết
- **Thống kê:**
  - Tổng thời gian chạy (ms và giây)
  - Số chu kỳ
  - Thời gian trung bình mỗi chu kỳ

### 4.3. Hiển Thị Land/Water Không Có Lưới

- **Aspect:** `no_grid` - Vẽ màu sắc nhưng không có border
- **Mục đích:** Phân biệt đất liền và nước mà không làm rối giao diện

---

## 5. Kết Luận

Mô hình này mô phỏng một cách chi tiết và thực tế quá trình sơ tán khi có sóng thần, với:

1. **Hệ thống đường giao thông tối ưu:** Đảm bảo tính kết nối và hiệu suất pathfinding
2. **Nhiều loại agents với hành vi khác nhau:** Locals, tourists, rescuers, và cars
3. **Mô phỏng sóng thần thực tế:** Tốc độ thay đổi theo địa hình, logic ngập lụt probabilistic
4. **Tối ưu hóa hiệu suất:** Pathfinding caching, spatial indexing, component filtering

Mô hình có thể được mở rộng để thêm các tính năng như:
- Nhiều loại phương tiện (xe máy, xe buýt)
- Hệ thống tín hiệu giao thông
- Mô phỏng tắc đường chi tiết hơn
- Phân tích thống kê nâng cao
