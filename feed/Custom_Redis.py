from collections import defaultdict
import sys
from redis import asyncio as aioredis
from yapic import json
import logging
from cryptofeed.backends.backend import BackendBookCallback, BackendCallback, BackendQueue
from cryptofeed.backends.redis import BookRedis, BookStream, CandlesRedis, FundingRedis, OpenInterestRedis, TradeRedis, BookSnapshotRedisKey, RedisZSetCallback, RedisCallback
logging.basicConfig(stream=sys.stdout, level=logging.INFO, format='%(asctime)s:%(levelname)s:%(message)s')
#logger = logging.getLogger(__name__)
class CustomRedisCallback(RedisCallback):
    def __init__(self, host='127.0.0.1', port=6379, socket=None, key=None, none_to='None', numeric_type=float, score_key='timestamp', ttl=3600, ssl=True, decode_responses=True, **kwargs):
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
        self.score_key = score_key
        self.ttl = ttl  # Add this line to store the TTL value
        
class CustomRedisZSetCallback(CustomRedisCallback):
    def __init__(self, host='127.0.0.1', port=6379, socket=None, key=None, numeric_type=float, score_key='timestamp', ttl=3600, ssl=True, decode_responses=True, **kwargs):
        """
        Custom Redis ZSet Callback with SSL and decode_responses support.
        """
        super().__init__(host=host, port=port, socket=socket, key=key, numeric_type=numeric_type, score_key=score_key, decode_responses=decode_responses, **kwargs)
        
    async def writer(self):
        # Modify the Redis connection to include decode_responses
        #print("CustomRedisZSetCallback writer started")
        conn = await aioredis.from_url(self.redis, decode_responses=self.decode_responses)
        while self.running:
            #print("Entering the async with self.read_queue() block")
            async with self.read_queue() as updates:
                #print("Updates received, processing...")
                #if not updates:
                    #print("No updates to process")
                    #continue
                async with conn.pipeline(transaction=False) as pipe:
                    for update in updates:
                        try:
                            #print(f"Processing update: {update}")
                            key = f"{self.key}-{update['exchange']}-{update['symbol']}"
                            score = update[self.score_key]
                            value = json.dumps(update)
                            #print(f"Adding to pipeline - Key: {key}, Score: {score}, Value: {value}")
                            pipe.zadd(key, {value: score}, nx=True)
                            # Set TTL for the key
                            pipe.expire(key, self.ttl)
                        except Exception as e:
                            logging.error(f"Error processing update: {e}")
                    #print("Executing pipeline")
                    try:
                        await pipe.execute()
                        #print("Pipeline executed successfully")
                    except Exception as e:
                        logging.error(f"Error executing pipeline: {e}")

        await conn.aclose()
        await conn.connection_pool.disconnect()


class CustomBookRedis(CustomRedisZSetCallback, BackendBookCallback):
    default_key = 'book'
    def __init__(self, *args, snapshots_only=False, snapshot_interval=10000, score_key='receipt_timestamp', **kwargs):
        self.snapshots_only = snapshots_only
        self.snapshot_interval = snapshot_interval
        self.snapshot_count = defaultdict(int)
        super().__init__(*args, score_key=score_key, **kwargs)
        logging.info("Initializing BookRedis")

class CustomTradeRedis(CustomRedisZSetCallback, BackendCallback):
    default_key = 'trades'
    logging.info("Initializing TradeRedis")
    
class CustomRedisStreamCallback(CustomRedisCallback):
    async def writer(self):
        conn = await aioredis.from_url(self.redis, decode_responses=self.decode_responses)

        while self.running:
            async with self.read_queue() as updates:
                async with conn.pipeline(transaction=False) as pipe:
                    for update in updates:
                        try:
                            if 'delta' in update:
                                update['delta'] = json.dumps(update['delta'])
                                #logging.info(f"Processing delta for {update['exchange']}-{update['symbol']}")
                            elif 'book' in update:
                                update['book'] = json.dumps(update['book'])
                                #logging.info(f"Processing full snapshot for {update['exchange']}-{update['symbol']}")
                            elif 'closed' in update:
                                update['closed'] = str(update['closed'])
                            # SET  <key> <value>    
                            full_key = f"{self.key}-{update['exchange']}-{update['symbol']}"
                            pipe = pipe.xadd(full_key, update)
                            # Set TTL for the key
                            pipe.expire(full_key, self.ttl)
                        except Exception as e:
                            logging.error(f"Error processing update: {e}")
                    try:
                        await pipe.execute()
                    except Exception as e:
                            logging.error(f"Error executing pipeline: {e}")

        await conn.aclose()
        await conn.connection_pool.disconnect()
        

class CustomBookStream(CustomRedisStreamCallback, BackendBookCallback):
    default_key = 'book'
    def __init__(self, *args, snapshots_only=False, snapshot_interval=10000, **kwargs):
        self.snapshots_only = snapshots_only
        self.snapshot_interval = snapshot_interval
        self.snapshot_count = defaultdict(int)
        super().__init__(*args, **kwargs)
        logging.info("Initializing BookStreamRedis")