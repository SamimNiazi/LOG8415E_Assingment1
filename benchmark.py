"""
Send 1000 concurrent requests to a target and report latency stats.
Usage: python benchmark.py <base_url> <route> [num_requests]
Example: python benchmark.py http://my-alb-dns.amazonaws.com /cluster1
"""
import asyncio
import statistics
import sys
import time

import aiohttp


async def call_endpoint(session, url):
    start = time.perf_counter()
    try:
        async with session.get(url) as response:
            await response.json()
            return response.status, time.perf_counter() - start
    except Exception:
        return None, None


async def main(base_url, route, num_requests=1000):
    url = f"{base_url}{route}"
    start_time = time.time()
    async with aiohttp.ClientSession() as session:
        tasks = [call_endpoint(session, url) for _ in range(num_requests)]
        results = await asyncio.gather(*tasks)
    wall_time = time.time() - start_time

    latencies = [lat for status, lat in results if status == 200]
    failures = sum(1 for status, _ in results if status != 200)

    print(f"\n=== Benchmark: {url} ===")
    print(f"Requests: {num_requests}  Success: {len(latencies)}  Failed: {failures}")
    print(f"Wall time: {wall_time:.2f}s")
    if latencies:
        sorted_lat = sorted(latencies)
        print(f"Avg: {statistics.mean(latencies)*1000:.2f} ms")
        print(f"Median: {statistics.median(latencies)*1000:.2f} ms")
        print(f"p95: {sorted_lat[int(len(sorted_lat)*0.95)]*1000:.2f} ms")
        print(f"Min/Max: {min(latencies)*1000:.2f} / {max(latencies)*1000:.2f} ms")


if __name__ == "__main__":
    base_url = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8000"
    route = sys.argv[2] if len(sys.argv) > 2 else "/cluster1"
    n = int(sys.argv[3]) if len(sys.argv) > 3 else 1000
    asyncio.run(main(base_url, route, n))
