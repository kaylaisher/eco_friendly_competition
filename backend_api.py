"""
🌱 Green Commute Carbon Tracker — Backend API
FastAPI + PostgreSQL + TDX Integration
"""

import os
import uuid
import math
import secrets
from datetime import datetime, timedelta, date
from typing import Optional
from enum import Enum

import httpx
from fastapi import FastAPI, HTTPException, Depends, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
from sqlalchemy import create_engine, text
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession
from sqlalchemy.orm import sessionmaker

# ============================================================
# Config
# ============================================================

DATABASE_URL = os.getenv("DATABASE_URL", "postgresql+asyncpg://user:pass@localhost:5432/green_commute")
TDX_BASE_URL = "https://tdx.transportdata.tw/api/basic"
TDX_CLIENT_ID = os.getenv("TDX_CLIENT_ID", "")
TDX_CLIENT_SECRET = os.getenv("TDX_CLIENT_SECRET", "")
JWT_SECRET = os.getenv("JWT_SECRET", "your-secret-key")

# 中壢車站 & 中央大學座標
ZHONGLI_STATION = (24.9537, 121.2257)
NCU_CAMPUS = (24.9681, 121.1948)
GEOFENCE_RADIUS_M = 200  # 地理圍欄半徑

# 監控路線
MONITORED_ROUTES = ["132", "172", "133"]

app = FastAPI(title="Green Commute API", version="1.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ============================================================
# Enums & Models
# ============================================================

class TransportMode(str, Enum):
    WALKING = "walking"
    CYCLING = "cycling"
    BUS = "bus"
    HSR = "hsr"
    CAR = "car"
    MOTORCYCLE = "motorcycle"
    UNKNOWN = "unknown"


class TripStatus(str, Enum):
    RECORDING = "recording"
    COMPLETED = "completed"
    CANCELLED = "cancelled"
    FLAGGED = "flagged"


# Carbon emission factors (g CO₂ per km) — 台灣環境部參考值
EMISSION_FACTORS = {
    TransportMode.WALKING:    {"co2_per_km": 0.0,   "points": 30},
    TransportMode.CYCLING:    {"co2_per_km": 0.0,   "points": 20},
    TransportMode.BUS:        {"co2_per_km": 40.0,  "points": 10},
    TransportMode.HSR:        {"co2_per_km": 25.0,  "points": 5},
    TransportMode.CAR:        {"co2_per_km": 150.0, "points": 0},
    TransportMode.MOTORCYCLE: {"co2_per_km": 70.0,  "points": 0},
}

# Baseline: driving a car (for "carbon saved" calculation)
BASELINE_CO2_PER_KM = 150.0


# ============================================================
# Request / Response Models
# ============================================================

class GPSPoint(BaseModel):
    latitude: float
    longitude: float
    speed_kmh: Optional[float] = None
    accuracy_m: Optional[float] = None
    altitude_m: Optional[float] = None
    recorded_at: datetime


class StartTripRequest(BaseModel):
    user_id: str
    start_latitude: float
    start_longitude: float
    start_time: datetime


class EndTripRequest(BaseModel):
    trip_id: str
    end_latitude: float
    end_longitude: float
    end_time: datetime
    gps_trail: list[GPSPoint]
    core_motion_activity: Optional[str] = None  # walking / cycling / automotive


class TripResponse(BaseModel):
    trip_id: str
    transport_mode: str
    distance_km: float
    carbon_emission_g: float
    carbon_saved_g: float
    points_earned: int
    bus_match_score: Optional[float] = None
    matched_route: Optional[str] = None


class RedeemRequest(BaseModel):
    user_id: str
    reward_id: str


class RedeemResponse(BaseModel):
    redemption_id: str
    voucher_code: str
    points_remaining: int


class LeaderboardEntry(BaseModel):
    rank: int
    user_name: str
    student_id: str
    carbon_saved_kg: float
    total_points: int
    trip_count: int


# ============================================================
# TDX API Client — 查詢即時公車動態
# ============================================================

class TDXClient:
    """台灣 TDX 運輸資料流通服務 API 客戶端"""

    def __init__(self):
        self.base_url = TDX_BASE_URL
        self.token: Optional[str] = None
        self.token_expires: Optional[datetime] = None

    async def _get_token(self) -> str:
        """取得 TDX API access token"""
        if self.token and self.token_expires and datetime.now() < self.token_expires:
            return self.token

        async with httpx.AsyncClient() as client:
            resp = await client.post(
                "https://tdx.transportdata.tw/auth/realms/TDXConnect/protocol/openid-connect/token",
                data={
                    "grant_type": "client_credentials",
                    "client_id": TDX_CLIENT_ID,
                    "client_secret": TDX_CLIENT_SECRET,
                },
            )
            data = resp.json()
            self.token = data["access_token"]
            self.token_expires = datetime.now() + timedelta(seconds=data.get("expires_in", 86400) - 60)
            return self.token

    async def get_realtime_buses(self, route_names: list[str], city: str = "Taoyuan") -> list[dict]:
        """
        查詢指定路線的即時公車位置
        Returns: [{ "route": "132", "bus_id": "...", "lat": ..., "lon": ..., "speed": ..., "direction": 0|1 }]
        """
        token = await self._get_token()
        headers = {"Authorization": f"Bearer {token}"}

        route_filter = " or ".join([f"RouteName/Zh_tw eq '{r}'" for r in route_names])
        url = f"{self.base_url}/v2/Bus/RealTimeByFrequency/City/{city}"
        params = {"$filter": route_filter, "$format": "JSON"}

        async with httpx.AsyncClient() as client:
            resp = await client.get(url, headers=headers, params=params)
            if resp.status_code != 200:
                return []

            buses = []
            for item in resp.json():
                buses.append({
                    "route": item.get("RouteName", {}).get("Zh_tw", ""),
                    "bus_id": item.get("PlateNumb", ""),
                    "lat": item.get("BusPosition", {}).get("PositionLat", 0),
                    "lon": item.get("BusPosition", {}).get("PositionLon", 0),
                    "speed": item.get("Speed", 0),
                    "direction": item.get("Direction", 0),  # 0=去程 1=返程
                    "duty_status": item.get("DutyStatus", 0),  # 0=正常 1=開始 2=結束
                })
            return buses

    async def get_route_stops(self, route_name: str, city: str = "Taoyuan") -> list[dict]:
        """取得路線站點座標"""
        token = await self._get_token()
        headers = {"Authorization": f"Bearer {token}"}

        url = f"{self.base_url}/v2/Bus/StopOfRoute/City/{city}"
        params = {
            "$filter": f"RouteName/Zh_tw eq '{route_name}'",
            "$format": "JSON",
        }

        async with httpx.AsyncClient() as client:
            resp = await client.get(url, headers=headers, params=params)
            if resp.status_code != 200:
                return []

            stops = []
            for route_data in resp.json():
                for stop in route_data.get("Stops", []):
                    pos = stop.get("StopPosition", {})
                    stops.append({
                        "name": stop.get("StopName", {}).get("Zh_tw", ""),
                        "lat": pos.get("PositionLat", 0),
                        "lon": pos.get("PositionLon", 0),
                        "sequence": stop.get("StopSequence", 0),
                    })
            return sorted(stops, key=lambda s: s["sequence"])

    async def get_estimated_arrival(self, route_name: str, city: str = "Taoyuan") -> list[dict]:
        """取得預估到站時間"""
        token = await self._get_token()
        headers = {"Authorization": f"Bearer {token}"}

        url = f"{self.base_url}/v2/Bus/EstimatedTimeOfArrival/City/{city}"
        params = {
            "$filter": f"RouteName/Zh_tw eq '{route_name}'",
            "$format": "JSON",
        }

        async with httpx.AsyncClient() as client:
            resp = await client.get(url, headers=headers, params=params)
            if resp.status_code != 200:
                return []

            arrivals = []
            for item in resp.json():
                arrivals.append({
                    "stop_name": item.get("StopName", {}).get("Zh_tw", ""),
                    "estimate_sec": item.get("EstimateTime"),  # None = 未發車
                    "stop_status": item.get("StopStatus", -1),  # 0=正常 1=尚未發車 2=交管 3=末班已過 4=今日未營運
                })
            return arrivals


tdx_client = TDXClient()


# ============================================================
# Core Algorithm — 交通工具辨識引擎
# ============================================================

def haversine_distance(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """計算兩點間距離 (公里)"""
    R = 6371.0
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = math.sin(dlat / 2) ** 2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlon / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def calculate_total_distance(gps_trail: list[GPSPoint]) -> float:
    """從 GPS 軌跡計算總行駛距離 (km)"""
    total = 0.0
    for i in range(1, len(gps_trail)):
        total += haversine_distance(
            gps_trail[i - 1].latitude, gps_trail[i - 1].longitude,
            gps_trail[i].latitude, gps_trail[i].longitude,
        )
    return round(total, 3)


def calculate_avg_speed(gps_trail: list[GPSPoint]) -> float:
    """計算平均速度 (km/h)"""
    if len(gps_trail) < 2:
        return 0.0
    distance = calculate_total_distance(gps_trail)
    time_diff = (gps_trail[-1].recorded_at - gps_trail[0].recorded_at).total_seconds() / 3600
    return distance / time_diff if time_diff > 0 else 0.0


def match_gps_to_bus_stops(
    gps_trail: list[GPSPoint],
    bus_stops: list[dict],
    tolerance_m: float = 80.0,
) -> float:
    """
    比對 GPS 軌跡與公車站點序列
    Returns: 0.0 ~ 1.0 吻合度分數
    """
    if not bus_stops:
        return 0.0

    matched_stops = 0
    tolerance_km = tolerance_m / 1000.0

    for stop in bus_stops:
        for point in gps_trail:
            dist = haversine_distance(point.latitude, point.longitude, stop["lat"], stop["lon"])
            if dist <= tolerance_km:
                matched_stops += 1
                break

    return round(matched_stops / len(bus_stops), 4)


def detect_stop_pattern(gps_trail: list[GPSPoint], bus_stops: list[dict]) -> bool:
    """
    偵測「走走停停」模式：公車會在站點短暫停靠 (15~45秒)
    自駕車不會在公車站點停留
    """
    if len(gps_trail) < 10:
        return False

    stop_events = 0
    tolerance_km = 0.08  # 80m

    for stop in bus_stops:
        # 找出在該站點附近 (80m) 且速度接近 0 的軌跡點
        near_points = [
            p for p in gps_trail
            if haversine_distance(p.latitude, p.longitude, stop["lat"], stop["lon"]) <= tolerance_km
               and p.speed_kmh is not None
               and p.speed_kmh < 3.0
        ]
        if len(near_points) >= 2:  # 至少 2 個低速軌跡點 ≈ 停靠中
            stop_events += 1

    # 如果在 ≥ 40% 的站點偵測到停靠行為，視為公車模式
    return stop_events >= len(bus_stops) * 0.4


async def classify_transport(
    gps_trail: list[GPSPoint],
    start_time: datetime,
    core_motion_hint: Optional[str] = None,
) -> dict:
    """
    🧠 核心辨識邏輯：三道篩選
    Returns: { "mode": TransportMode, "bus_match_score": float, "matched_route": str|None }
    """

    avg_speed = calculate_avg_speed(gps_trail)

    # ── 第一道：低速 → 步行或腳踏車 ──
    if avg_speed < 5.0:
        mode = TransportMode.WALKING
        if core_motion_hint == "cycling" or (3.0 <= avg_speed < 5.0):
            mode = TransportMode.CYCLING
        return {"mode": mode, "bus_match_score": None, "matched_route": None}

    # ── 第二道：高速 (> 80 km/h) → 可能是高鐵 ──
    if avg_speed > 80.0:
        return {"mode": TransportMode.HSR, "bus_match_score": None, "matched_route": None}

    # ── 第三道：中速 → 查 TDX 判斷公車 or 自駕 ──

    # 3a. 查詢此刻是否有公車班次在跑
    try:
        active_buses = await tdx_client.get_realtime_buses(MONITORED_ROUTES)
    except Exception:
        active_buses = []

    # 也查看預估到站資訊 (確認是否營運中)
    any_route_active = False
    for route_name in MONITORED_ROUTES:
        try:
            arrivals = await tdx_client.get_estimated_arrival(route_name)
            for arr in arrivals:
                # stop_status 0 = 正常預估中 → 有車在跑
                if arr.get("stop_status") == 0 and arr.get("estimate_sec") is not None:
                    any_route_active = True
                    break
        except Exception:
            continue
        if any_route_active:
            break

    # 如果沒有任何班次在營運 → 直接判定自駕
    if not active_buses and not any_route_active:
        mode = TransportMode.CAR
        if core_motion_hint == "cycling":
            mode = TransportMode.CYCLING
        elif avg_speed < 40:
            mode = TransportMode.MOTORCYCLE if avg_speed < 30 else TransportMode.CAR
        return {"mode": mode, "bus_match_score": 0.0, "matched_route": None}

    # 3b. 有班次在跑 → 比對 GPS 軌跡與公車路線
    best_score = 0.0
    best_route = None

    for route_name in MONITORED_ROUTES:
        try:
            stops = await tdx_client.get_route_stops(route_name)
        except Exception:
            continue

        # 路線吻合度
        score = match_gps_to_bus_stops(gps_trail, stops, tolerance_m=80)

        # 停站模式加分
        if detect_stop_pattern(gps_trail, stops):
            score = min(1.0, score + 0.2)

        if score > best_score:
            best_score = score
            best_route = route_name

    # 3c. 根據吻合度判定
    if best_score >= 0.6:
        return {
            "mode": TransportMode.BUS,
            "bus_match_score": best_score,
            "matched_route": best_route,
        }
    elif best_score >= 0.3:
        # 中間地帶：標記讓用戶手動確認
        return {
            "mode": TransportMode.UNKNOWN,
            "bus_match_score": best_score,
            "matched_route": best_route,
        }
    else:
        return {
            "mode": TransportMode.CAR,
            "bus_match_score": best_score,
            "matched_route": None,
        }


def calculate_carbon(distance_km: float, mode: TransportMode) -> dict:
    """計算碳排放量與減碳量"""
    factor = EMISSION_FACTORS.get(mode, EMISSION_FACTORS[TransportMode.CAR])
    emission = round(distance_km * factor["co2_per_km"], 2)
    saved = round(distance_km * BASELINE_CO2_PER_KM - emission, 2)
    saved = max(0, saved)  # 不會是負數

    return {
        "carbon_emission_g": emission,
        "carbon_saved_g": saved,
        "points_earned": factor["points"],
    }


# ============================================================
# Anti-Fraud — 防作弊檢查
# ============================================================

async def anti_fraud_check(user_id: str, trip_start: datetime, distance_km: float) -> dict:
    """
    基本防作弊機制
    Returns: { "passed": bool, "reason": str }
    """
    # Rule 1: 單趟距離合理性 (中壢↔中大約 7~8 km)
    if distance_km > 15.0:
        return {"passed": False, "reason": "distance_too_long"}
    if distance_km < 2.0:
        return {"passed": False, "reason": "distance_too_short"}

    # Rule 2: 一天最多 4 趟 (來回各 2 次)
    # (Actual DB query would go here)
    # today_trips = await db.count_trips(user_id, trip_start.date())
    # if today_trips >= 4:
    #     return {"passed": False, "reason": "daily_limit_exceeded"}

    # Rule 3: 兩趟之間至少間隔 30 分鐘
    # last_trip = await db.get_last_trip(user_id)
    # if last_trip and (trip_start - last_trip.end_time).total_seconds() < 1800:
    #     return {"passed": False, "reason": "too_frequent"}

    return {"passed": True, "reason": "ok"}


# ============================================================
# API Endpoints
# ============================================================

@app.post("/api/v1/trips/start", response_model=dict)
async def start_trip(req: StartTripRequest):
    """
    開始記錄通勤 (由 iOS geofence 觸發)
    """
    trip_id = str(uuid.uuid4())
    # In production: INSERT INTO trips (id, user_id, start_time, start_location, status)
    return {
        "trip_id": trip_id,
        "status": "recording",
        "message": "Trip recording started. Upload GPS trail when complete.",
    }


@app.post("/api/v1/trips/end", response_model=TripResponse)
async def end_trip(req: EndTripRequest):
    """
    結束通勤 → 執行辨識 + 碳排計算 + 發放積分
    """
    # 1. 計算距離
    distance = calculate_total_distance(req.gps_trail)

    # 2. 防作弊檢查
    fraud = await anti_fraud_check(req.trip_id, req.end_time, distance)
    if not fraud["passed"]:
        raise HTTPException(status_code=400, detail=f"Trip flagged: {fraud['reason']}")

    # 3. 交通工具辨識
    classification = await classify_transport(
        gps_trail=req.gps_trail,
        start_time=req.gps_trail[0].recorded_at if req.gps_trail else req.end_time,
        core_motion_hint=req.core_motion_activity,
    )
    mode = classification["mode"]

    # 4. 碳排計算
    carbon = calculate_carbon(distance, mode)

    # 5. 如果是 UNKNOWN 模式，暫不給分，等用戶確認
    if mode == TransportMode.UNKNOWN:
        carbon["points_earned"] = 0

    # 6. In production: UPDATE trips, INSERT point_transactions, UPDATE users.total_points
    # await db.complete_trip(...)

    return TripResponse(
        trip_id=req.trip_id,
        transport_mode=mode.value,
        distance_km=distance,
        carbon_emission_g=carbon["carbon_emission_g"],
        carbon_saved_g=carbon["carbon_saved_g"],
        points_earned=carbon["points_earned"],
        bus_match_score=classification.get("bus_match_score"),
        matched_route=classification.get("matched_route"),
    )


@app.post("/api/v1/trips/{trip_id}/confirm")
async def confirm_transport_mode(trip_id: str, mode: TransportMode):
    """
    用戶手動確認/修正交通方式 (當自動辨識不確定時)
    """
    # In production: UPDATE trips SET transport_mode, recalculate points
    carbon = calculate_carbon(7.5, mode)  # Use stored distance
    return {
        "trip_id": trip_id,
        "confirmed_mode": mode.value,
        "points_earned": carbon["points_earned"],
        "message": "Transport mode confirmed. Points updated.",
    }


@app.get("/api/v1/trips/history")
async def get_trip_history(
    user_id: str,
    page: int = Query(1, ge=1),
    limit: int = Query(20, ge=1, le=100),
):
    """取得通勤歷史紀錄"""
    # In production: SELECT * FROM trips WHERE user_id = ... ORDER BY start_time DESC
    return {
        "user_id": user_id,
        "page": page,
        "limit": limit,
        "trips": [],  # Populated from DB
    }


@app.get("/api/v1/users/{user_id}/stats")
async def get_user_stats(user_id: str):
    """取得用戶碳排統計"""
    # In production: aggregate from trips + daily_stats
    return {
        "user_id": user_id,
        "total_points": 0,
        "total_trips": 0,
        "total_distance_km": 0,
        "total_carbon_saved_kg": 0,
        "this_month": {
            "trips": 0,
            "carbon_saved_kg": 0,
            "points_earned": 0,
        },
        "mode_breakdown": {
            "walking": 0,
            "cycling": 0,
            "bus": 0,
            "car": 0,
        },
    }


# ── Rewards Endpoints ──

@app.get("/api/v1/rewards")
async def list_rewards():
    """列出所有可兌換獎品"""
    # In production: SELECT * FROM rewards WHERE is_active = TRUE AND stock > 0
    return {"rewards": []}


@app.post("/api/v1/rewards/redeem", response_model=RedeemResponse)
async def redeem_reward(req: RedeemRequest):
    """兌換獎品"""
    # In production:
    # 1. Check user has enough points
    # 2. Check reward stock > 0
    # 3. Deduct points, reduce stock
    # 4. Generate voucher code
    # 5. INSERT into redemptions + point_transactions
    voucher_code = f"GC-{secrets.token_hex(4).upper()}"
    return RedeemResponse(
        redemption_id=str(uuid.uuid4()),
        voucher_code=voucher_code,
        points_remaining=0,
    )


# ── Leaderboard ──

@app.get("/api/v1/leaderboard")
async def get_leaderboard(
    period: str = Query("month", regex="^(week|month|semester)$"),
    limit: int = Query(20, ge=1, le=100),
):
    """取得減碳排行榜"""
    # In production: query monthly_leaderboard view
    return {"period": period, "entries": []}


# ── Bus Schedule Check (for iOS prefetch) ──

@app.get("/api/v1/bus/active")
async def check_active_buses():
    """
    iOS 端可呼叫此 endpoint 預先檢查是否有班次
    用於在通勤開始前就提供用戶資訊
    """
    try:
        buses = await tdx_client.get_realtime_buses(MONITORED_ROUTES)
        return {
            "has_active_buses": len(buses) > 0,
            "active_routes": list(set(b["route"] for b in buses)),
            "bus_count": len(buses),
            "checked_at": datetime.now().isoformat(),
        }
    except Exception as e:
        return {"has_active_buses": None, "error": str(e)}


# ============================================================
# Health Check
# ============================================================

@app.get("/health")
async def health_check():
    return {"status": "ok", "service": "green-commute-api", "version": "1.0.0"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
