import arctic
import pandas as pd
import asyncio
from redis import asyncio as aioredis
from datetime import datetime, timezone
import time
from statistics import mean
import logging
logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO)
import yaml
with open('/config_cf.yaml', 'r') as file:
    config = yaml.safe_load(file)

user = config['mongodb_username']
password = config['mongodb_password']
redis_host = config['redis_host']
redis_port = config['redis_port']
async def monitor_redis_memory(redis_host, redis_port, channel, threshold=70, use_ssl=True):
    url = f"rediss://{redis_host}:{redis_port}" if use_ssl else f"redis://{redis_host}:{redis_port}"
    r = await aioredis.from_url(url, decode_responses=True)
    while True:
        try:
            info = await r.info('memory')
            used_memory = info['used_memory']
            max_memory = info['maxmemory']
            memory_usage = (used_memory / max_memory) * 100 if max_memory else 0
            if memory_usage > threshold:
                await publish_message(redis_host, redis_port, channel, "Memory threshold exceeded", use_ssl)
        except Exception as e:
            logging.error(f"Error checking Redis memory: {e}")
        await asyncio.sleep(60)  # Check every 60 seconds
async def publish_message(redis_host, redis_port, channel, message, use_ssl=True):
    try:
        url = f"rediss://{redis_host}:{redis_port}" if use_ssl else f"redis://{redis_host}:{redis_port}"
        r = await aioredis.from_url(url, decode_responses=True)
        await r.publish(channel, message)
    except Exception as e:
        logging.error(f"Error publishing message: {e}")
        
async def redis_subscriber(redis_host, redis_port, channel, use_ssl=True):
    url = f"rediss://{redis_host}:{redis_port}" if use_ssl else f"redis://{redis_host}:{redis_port}"
    r = await aioredis.from_url(url, decode_responses=True)
    pubsub = await r.pubsub()
    await pubsub.subscribe(channel)

    async for message in pubsub.listen():
        try:
            if message['type'] == 'message':
                await handle_message(message['data'])
        except Exception as e:
            logging.error(f"Error handling message: {e}")


async def handle_message(message):
    try:
        # Implement the logic to transfer data to Arctic and delete from Redis
        transfer_data_to_arctic(redis_client, arctic_callback, key)
        
    except Exception as e:
        logging.error(f"Error handling message: {e}")

async def transfer_data_to_arctic(redis_client, arctic_callback, key):
    try:
        # Fetch data from Redis
        data = await redis_client.get(key)
        # Process and store in Arctic
        await arctic_callback.write(data)
    except Exception as e:
        logging.error(f"Error transferring data to Arctic: {e}")
        # Optionally delete the key from Redis to free space
    try:
        await redis_client.delete(key)
    except Exception as e:
        logging.error(f"Error deleting on Redis {e}")


class ArcticCallback:
    def __init__(self, library, host = f'mongodb://{user}:{password}@localhost:27017', key=None, none_to=None, numeric_type=float, quota=0, ssl=False, **kwargs):
        """
        library: str
            arctic library. Will be created if does not exist.
        key: str
            setting key lets you override the symbol name.
            The defaults are related to the data
            being stored, i.e. trade, funding, etc
        quota: int
            absolute number of bytes that this library is limited to.
            The default of 0 means that the storage size is unlimited.
        kwargs:
            if library needs to be created you can specify the
            lib_type in the kwargs. Default is VersionStore, but you can
            set to chunkstore with lib_type=arctic.CHUNK_STORE
        """
        con = arctic.Arctic(host, ssl=ssl)
        if library not in con.list_libraries():
            lib_type = kwargs.get('lib_type', arctic.VERSION_STORE)
            con.initialize_library(library, lib_type=lib_type)
        con.set_quota(library, quota)
        self.lib = con[library]
        self.key = key if key else self.default_key
        self.numeric_type = numeric_type
        self.none_to = none_to

    async def write(self, data):
        df = pd.DataFrame({key: [value] for key, value in data.items()})
        df['date'] = pd.to_datetime(df.timestamp, unit='s')
        df['receipt_timestamp'] = pd.to_datetime(df.receipt_timestamp, unit='s')
        df.set_index(['date'], inplace=True)
        if 'type' in df and df.type.isna().any():
            df.drop(columns=['type'], inplace=True)
        df.drop(columns=['timestamp'], inplace=True)
        self.lib.append(self.key, df, upsert=True)
        
class TradeArctic(ArcticCallback, BackendCallback):
    default_key = TRADES