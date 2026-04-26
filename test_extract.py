import httpx
import json

url = "http://127.0.0.1:9000/api/v1/extract"
payload = {
    "image_id": "d099a8b0-8886-4288-9ee2-c2430089a1ba",
    "roi_bbox": [0, 0, 800, 600]
}

print("Sending extract request...")
resp = httpx.post(url, json=payload, timeout=120)
print(f"Status: {resp.status_code}")
if resp.status_code == 200:
    data = resp.json()
    print(f"Record ID: {data['record']['id']}")
    print(f"Subject: {data['record']['subject']}")
    print(f"Type: {data['record']['type']}")
    print(f"Problem: {data['record']['problem'][:100]}...")
    print(f"Answer: {data['record']['answer']}")
    print(f"Assets: {len(data['record']['assets'])}")
else:
    print(f"Error: {resp.text[:500]}")
