-- ============================================================
-- 🌱 Green Commute Carbon Tracker — Database Schema
-- PostgreSQL + PostGIS
-- ============================================================

-- Enable extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "postgis";

-- ============================================================
-- 1. USERS — 學生帳號
-- ============================================================
CREATE TABLE users (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    student_id          VARCHAR(20) UNIQUE NOT NULL,        -- 學號
    email               VARCHAR(255) UNIQUE NOT NULL,       -- 校園信箱
    name                VARCHAR(100) NOT NULL,
    password_hash       VARCHAR(255) NOT NULL,
    avatar_url          VARCHAR(500),
    total_points        INTEGER NOT NULL DEFAULT 0,
    total_carbon_saved_kg NUMERIC(10,3) NOT NULL DEFAULT 0, -- 累計減碳 (kg)
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_users_student_id ON users(student_id);
CREATE INDEX idx_users_email ON users(email);

-- ============================================================
-- 2. EMISSION_FACTORS — 各交通方式碳排係數
-- ============================================================
CREATE TABLE emission_factors (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    transport_mode      VARCHAR(20) UNIQUE NOT NULL,  -- walking, cycling, bus, hsr, car, motorcycle
    co2_per_km_g        NUMERIC(8,2) NOT NULL,        -- 每公里碳排 (g CO₂)
    points_per_trip     INTEGER NOT NULL DEFAULT 0,    -- 每趟可獲積分
    description         VARCHAR(200),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 初始化碳排係數 (參考台灣環境部數據)
INSERT INTO emission_factors (transport_mode, co2_per_km_g, points_per_trip, description) VALUES
    ('walking',    0.00,   30, '步行 — 零碳排，最高獎勵'),
    ('cycling',    0.00,   20, '腳踏車 — 零碳排'),
    ('bus',       40.00,   10, '公車客運 — 低碳大眾運輸'),
    ('hsr',       25.00,    5, '高鐵 — 電力驅動低碳'),
    ('car',      150.00,    0, '自小客車 — 高碳排無獎勵'),
    ('motorcycle', 70.00,   0, '機車 — 中碳排無獎勵');

-- ============================================================
-- 3. BUS_ROUTES — 公車路線與站點資料
-- ============================================================
CREATE TABLE bus_routes (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tdx_route_id        VARCHAR(50) UNIQUE NOT NULL,  -- TDX 路線代碼
    route_name          VARCHAR(100) NOT NULL,         -- e.g. '132 中壢-中央大學'
    route_geometry      GEOMETRY(LINESTRING, 4326),    -- 路線軌跡 (PostGIS)
    stops_geojson       JSONB NOT NULL DEFAULT '[]',   -- 站點座標陣列
    avg_carbon_per_km_g NUMERIC(8,2) NOT NULL DEFAULT 40.00,
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_bus_routes_tdx ON bus_routes(tdx_route_id);
CREATE INDEX idx_bus_routes_geom ON bus_routes USING GIST(route_geometry);

-- 初始化中壢↔中大路線
INSERT INTO bus_routes (tdx_route_id, route_name, stops_geojson) VALUES
    ('TYC132', '132 中壢—中央大學', '[
        {"name":"中壢車站","lat":24.9537,"lon":121.2257},
        {"name":"中壢高中","lat":24.9571,"lon":121.2195},
        {"name":"中央大學","lat":24.9681,"lon":121.1948}
    ]'),
    ('TYC172', '172 中壢—中央大學(經內壢)', '[
        {"name":"中壢車站","lat":24.9537,"lon":121.2257},
        {"name":"內壢","lat":24.9612,"lon":121.2346},
        {"name":"中央大學","lat":24.9681,"lon":121.1948}
    ]');

-- ============================================================
-- 4. TRIPS — 通勤紀錄
-- ============================================================
CREATE TABLE trips (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id             UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    start_time          TIMESTAMPTZ NOT NULL,
    end_time            TIMESTAMPTZ,
    start_location      GEOMETRY(POINT, 4326),          -- 出發點
    end_location        GEOMETRY(POINT, 4326),           -- 到達點
    transport_mode      VARCHAR(20) NOT NULL DEFAULT 'unknown',
    distance_km         NUMERIC(8,3),                    -- 通勤距離
    carbon_emission_g   NUMERIC(10,2),                   -- 實際碳排 (g)
    carbon_saved_g      NUMERIC(10,2),                   -- 相較開車省下的碳排
    points_earned       INTEGER NOT NULL DEFAULT 0,
    bus_match_score     NUMERIC(5,4),                    -- 0~1 公車路線吻合度
    tdx_route_id        VARCHAR(50),                     -- 比對到的路線
    detection_method    VARCHAR(50) DEFAULT 'auto',      -- auto / manual_confirm
    status              VARCHAR(20) NOT NULL DEFAULT 'recording', -- recording / completed / cancelled / flagged
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_trips_user ON trips(user_id);
CREATE INDEX idx_trips_time ON trips(start_time DESC);
CREATE INDEX idx_trips_mode ON trips(transport_mode);
CREATE INDEX idx_trips_status ON trips(status);

-- ============================================================
-- 5. GPS_WAYPOINTS — GPS 軌跡點
-- ============================================================
CREATE TABLE gps_waypoints (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    trip_id             UUID NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
    location            GEOMETRY(POINT, 4326) NOT NULL,
    latitude            NUMERIC(10,7) NOT NULL,
    longitude           NUMERIC(10,7) NOT NULL,
    speed_kmh           NUMERIC(6,2),
    accuracy_m          NUMERIC(6,2),
    altitude_m          NUMERIC(8,2),
    recorded_at         TIMESTAMPTZ NOT NULL
);

CREATE INDEX idx_waypoints_trip ON gps_waypoints(trip_id);
CREATE INDEX idx_waypoints_time ON gps_waypoints(recorded_at);
CREATE INDEX idx_waypoints_geom ON gps_waypoints USING GIST(location);

-- ============================================================
-- 6. POINT_TRANSACTIONS — 積分異動紀錄
-- ============================================================
CREATE TABLE point_transactions (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id             UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    trip_id             UUID REFERENCES trips(id) ON DELETE SET NULL,
    points              INTEGER NOT NULL,               -- 正數=獲得, 負數=花費
    type                VARCHAR(30) NOT NULL,           -- trip_reward / redemption / bonus / adjustment
    description         VARCHAR(300),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_point_tx_user ON point_transactions(user_id);
CREATE INDEX idx_point_tx_type ON point_transactions(type);

-- ============================================================
-- 7. REWARDS — 可兌換獎品
-- ============================================================
CREATE TABLE rewards (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name                VARCHAR(200) NOT NULL,
    description         TEXT,
    image_url           VARCHAR(500),
    points_required     INTEGER NOT NULL,
    stock               INTEGER NOT NULL DEFAULT 0,     -- 庫存
    partner_name        VARCHAR(200),                   -- 合作商家
    category            VARCHAR(50),                    -- food / drink / stationery / other
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 初始化範例獎品
INSERT INTO rewards (name, description, points_required, stock, partner_name, category) VALUES
    ('7-11 50元禮券',      '校內7-11消費折抵',           100, 200, '7-ELEVEN', 'food'),
    ('松果咖啡 美式一杯',   '中大校內松果咖啡兌換',        80, 100, '松果咖啡', 'drink'),
    ('敦煌書局 100元折價券', '校內書局消費折抵',           300, 50,  '敦煌書局', 'stationery'),
    ('全家 霜淇淋兌換券',    '全家便利商店霜淇淋一支',      50,  300, '全家便利商店', 'food');

-- ============================================================
-- 8. REDEMPTIONS — 兌換紀錄
-- ============================================================
CREATE TABLE redemptions (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id             UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    reward_id           UUID NOT NULL REFERENCES rewards(id),
    points_spent        INTEGER NOT NULL,
    voucher_code        VARCHAR(50) UNIQUE NOT NULL,    -- 兌換券序號
    status              VARCHAR(20) NOT NULL DEFAULT 'issued', -- issued / used / expired
    expires_at          TIMESTAMPTZ,
    redeemed_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_redemptions_user ON redemptions(user_id);
CREATE INDEX idx_redemptions_status ON redemptions(status);
CREATE INDEX idx_redemptions_voucher ON redemptions(voucher_code);

-- ============================================================
-- 9. GEOFENCES — 地理圍欄設定
-- ============================================================
CREATE TABLE geofences (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name                VARCHAR(100) NOT NULL,
    center              GEOMETRY(POINT, 4326) NOT NULL,
    radius_m            INTEGER NOT NULL DEFAULT 200,
    fence_type          VARCHAR(20) NOT NULL,           -- origin / destination
    is_active           BOOLEAN NOT NULL DEFAULT TRUE
);

-- 中壢車站 & 中央大學圍欄
INSERT INTO geofences (name, center, radius_m, fence_type) VALUES
    ('中壢車站', ST_SetSRID(ST_MakePoint(121.2257, 24.9537), 4326), 200, 'origin'),
    ('中央大學', ST_SetSRID(ST_MakePoint(121.1948, 24.9681), 4326), 300, 'destination');

-- ============================================================
-- 10. DAILY_STATS — 每日統計 (materialized view or table)
-- ============================================================
CREATE TABLE daily_stats (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id             UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    date                DATE NOT NULL,
    trip_count          INTEGER NOT NULL DEFAULT 0,
    total_distance_km   NUMERIC(8,3) NOT NULL DEFAULT 0,
    total_carbon_g      NUMERIC(10,2) NOT NULL DEFAULT 0,
    total_carbon_saved_g NUMERIC(10,2) NOT NULL DEFAULT 0,
    total_points        INTEGER NOT NULL DEFAULT 0,
    primary_mode        VARCHAR(20),
    UNIQUE(user_id, date)
);

CREATE INDEX idx_daily_stats_user_date ON daily_stats(user_id, date DESC);

-- ============================================================
-- Useful Views
-- ============================================================

-- 排行榜 view: 本月減碳排名
CREATE VIEW monthly_leaderboard AS
SELECT
    u.id,
    u.name,
    u.student_id,
    SUM(t.carbon_saved_g) / 1000.0 AS carbon_saved_kg,
    SUM(t.points_earned) AS month_points,
    COUNT(t.id) AS trip_count
FROM users u
JOIN trips t ON t.user_id = u.id
WHERE t.status = 'completed'
  AND t.start_time >= DATE_TRUNC('month', NOW())
GROUP BY u.id, u.name, u.student_id
ORDER BY carbon_saved_kg DESC;

-- 各交通方式統計
CREATE VIEW transport_mode_stats AS
SELECT
    transport_mode,
    COUNT(*) AS trip_count,
    ROUND(AVG(distance_km), 2) AS avg_distance,
    ROUND(SUM(carbon_emission_g) / 1000.0, 2) AS total_carbon_kg,
    ROUND(SUM(carbon_saved_g) / 1000.0, 2) AS total_saved_kg
FROM trips
WHERE status = 'completed'
GROUP BY transport_mode;
