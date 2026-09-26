import os
import time
import logging

from fastapi import FastAPI, Request
import uvicorn

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI()

TEAM_SEED = 3165  # sorted(["idA","idB","idC"]) -> sha256 -> % 10000
INSTANCE_ID = os.environ.get("INSTANCE_ID", "0")
# Set per-instance at deploy time: "/cluster1" for the small cluster, "/cluster2" for the large one
CLUSTER_ROUTE = os.environ.get("CLUSTER_ROUTE", "/cluster1")


@app.middleware("http")
async def add_team_seed_header(request: Request, call_next):
    response = await call_next(request)
    response.headers["X-Team-Seed"] = str(TEAM_SEED)
    return response


@app.get("/")
async def root():
    return {"message": "Instance has received the request", "instance_id": INSTANCE_ID}


@app.get("/health")
async def health():
    return {"status": "ok", "instance_id": INSTANCE_ID}


@app.get(CLUSTER_ROUTE)
async def cluster_handler():
    message = f"Instance number {INSTANCE_ID} is responding now!"
    logger.info(message)
    return {
        "message": message,
        "instance_id": INSTANCE_ID,
        "team_seed": TEAM_SEED,
        "timestamp": time.time(),
    }


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
