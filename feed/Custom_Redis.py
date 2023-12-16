from collections import defaultdict

from redis import asyncio as aioredis
from yapic import json

from cryptofeed.backends.backend import BackendBookCallback, BackendCallback, BackendQueue
from cryptofeed.backends.redis import BookRedis, BookStream, CandlesRedis, FundingRedis, OpenInterestRedis, TradeRedis, BookSnapshotRedisKey, RedisZSetCallback, RedisCallback
class CustomRedisCallback(RedisCallback):
    def __init__(self, host='127.0.0.1', port=6379, socket=None, key=None, none_to='None', numeric_type=float, ssl=True, decode_responses=True, **kwargs):
        """
        Custom Redis Callback with SSL and decode_responses support.
        """
        prefix = 'rediss://' if ssl else 'redis://'
        if socket:
            prefix = 'unix://'
            port = None

        self.redis = f"{prefix}{host}" + f":{port}" if port else ""
        self.key = key if key else self.default_key
        self.numeric_type = numeric_type
        self.none_to = none_to
        self.running = True
        self.ssl = ssl
        self.decode_responses = decode_responses

class CustomRedisZSetCallback(CustomRedisCallback):
    def __init__(self, host='127.0.0.1', port=6379, socket=None, key=None, numeric_type=float, score_key='timestamp', ssl=True, decode_responses=True, **kwargs):
        """
        Custom Redis ZSet Callback with SSL and decode_responses support.
        """
        super().__init__(host=host, port=port, socket=socket, key=key, numeric_type=numeric_type, score_key=score_key, decode_responses=decode_responses, **kwargs)

    async def writer(self):
        # Modify the Redis connection to include decode_responses
        print("CustomRedisZSetCallback writer started")
        conn = await aioredis.from_url(self.redis, decode_responses=self.decode_responses)
        while self.running:
            async with self.read_queue() as updates:
                print("Processing updates in CustomRedisZSetCallback")
                async with conn.pipeline(transaction=False) as pipe:
                    print(f"Adding update to pipeline: {update}")
                    for update in updates:
                        pipe = pipe.zadd(f"{self.key}-{update['exchange']}-{update['symbol']}", {json.dumps(update): update[self.score_key]}, nx=True)
                        print("Executing pipeline")
                    await pipe.execute()

        await conn.aclose()
        await conn.connection_pool.disconnect()


class CustomBookRedis(CustomRedisZSetCallback, BackendBookCallback):
    default_key = 'book'

    def __init__(self, *args, snapshots_only=False, snapshot_interval=10, score_key='receipt_timestamp', **kwargs):
        print("Initializing CustomBookRedis")
        self.snapshots_only = snapshots_only
        self.snapshot_interval = snapshot_interval
        self.snapshot_count = defaultdict(int)
        super().__init__(*args, score_key=score_key, **kwargs)