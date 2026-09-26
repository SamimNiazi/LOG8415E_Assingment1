"""
Custom active-probing application load balancer (Section 3 / 5.2, option A).

Every PROBE_INTERVAL_SECONDS it hits /cluster1 and /cluster2 on every backend,
times the response, and routes new traffic to whichever instance in that
cluster is currently fastest. If the currently-selected instance's latency
climbs above FAILOVER_THRESHOLD_MS (or it stops responding), traffic moves to
the next-fastest healthy instance.

Team seed: 3165  ->  threshold = 50 + (3165 % 200) = 215 ms

Run this from the same directory as small_ips.txt / large_ips.txt
(created by deploy_app.sh).
"""
import asyncio
import time

import httpx
import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

TEAM_SEED = 3165
FAILOVER_THRESHOLD_MS = 50 + (TEAM_SEED % 200)  # 215 ms
PROBE_INTERVAL_SECONDS = 3
BACKEND_PORT = 8000


def load_targets():
    def read_ips(path):
        with open(path) as f:
            return [f"http://{ip.strip()}:{BACKEND_PORT}" for ip in f if ip.strip()]

    return {
        "/cluster1": read_ips("small_ips.txt"),
        "/cluster2": read_ips("large_ips.txt"),
    }


CLUSTERS = load_targets()
current_best = {route: None for route in CLUSTERS}
latencies = {route: {} for route in CLUSTERS}

app = FastAPI()


async def probe_once(client: httpx.AsyncClient, route: str, target: str):
    start = time.perf_counter()
    try:
        resp = await client.get(f"{target}{route}", timeout=2.0)
        elapsed_ms = (time.perf_counter() - start) * 1000
        return target, (elapsed_ms if resp.status_code == 200 else None)
    except Exception:
        return target, None


async def probe_loop():
    async with httpx.AsyncClient() as client:
        while True:
            for route, targets in CLUSTERS.items():
                results = await asyncio.gather(*[probe_once(client, route, t) for t in targets])
                healthy = {t: lat for t, lat in results if lat is not None}
                latencies[route] = healthy

                if not healthy:
                    print(f"[LB] {route}: no healthy targets!")
                    current_best[route] = None
                    continue

                best_target = min(healthy, key=healthy.get)
                prev = current_best[route]

                should_switch = (
                    prev is None
                    or prev not in healthy
                    or healthy[prev] > FAILOVER_THRESHOLD_MS
                )
                if should_switch and prev != best_target:
                    print(
                        f"[LB] {route}: switching {prev} -> {best_target} "
                        f"({healthy[best_target]:.1f} ms, threshold {FAILOVER_THRESHOLD_MS} ms)"
                    )
                    current_best[route] = best_target
                elif not should_switch and healthy.get(prev, 1e9) > healthy[best_target]:
                    current_best[route] = best_target  # minor improvement, no log spam

            await asyncio.sleep(PROBE_INTERVAL_SECONDS)


@app.on_event("startup")
async def startup():
    asyncio.create_task(probe_loop())


@app.get("/cluster1")
@app.get("/cluster2")
async def route_request(request: Request):
    route = request.url.path
    target = current_best.get(route)
    if target is None:
        return JSONResponse({"error": "no healthy backend"}, status_code=503)
    async with httpx.AsyncClient() as client:
        resp = await client.get(f"{target}{route}", timeout=3.0)
        return JSONResponse(
            resp.json(),
            headers={"X-Team-Seed": str(TEAM_SEED), "X-Routed-To": target},
        )


@app.get("/lb-status")
async def status():
    return {
        "current_best": current_best,
        "latencies_ms": latencies,
        "failover_threshold_ms": FAILOVER_THRESHOLD_MS,
        "team_seed": TEAM_SEED,
    }


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=9000)
