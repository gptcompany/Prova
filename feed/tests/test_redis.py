import redis
import asyncio
from datetime import datetime, timezone
from redis import asyncio as aioredis
import yaml
with open('/config_cf.yaml', 'r') as file:
    config = yaml.safe_load(file)
    
async def check_last_update(redis_host, redis_port, exchanges, symbols, use_ssl):
    try:
        # Connect to Redis
        url = f"rediss://{redis_host}:{redis_port}" if use_ssl else f"redis://{redis_host}:{redis_port}"
        r = await aioredis.from_url(url, decode_responses=True)

        while True:
            current_time = datetime.now(timezone.utc)
            print(f"Checking updates as of {current_time.isoformat()}")

            for exchange in exchanges:
                for symbol in symbols:
                    key_pattern = f"trades-{exchange}-{symbol}"
                    #print('before retrieve the entry in redis...')
                    # Retrieve the latest entry's score (timestamp)
                    last_update_score = await r.zrange(key_pattern, -1, -1, withscores=True)
                    if not last_update_score:
                        print(f"No data found for {key_pattern}")
                        continue

                    # Extract the timestamp (score) of the last update
                    _, last_timestamp = last_update_score[0]
                    last_update_time = datetime.fromtimestamp(last_timestamp, tz=timezone.utc)

                    print(f"Last update for {key_pattern}: {last_update_time.isoformat()}")

            await asyncio.sleep(3)  # Wait for 3 seconds before next check

    except Exception as e:
        print(f"Error occurred: {e}")


async def subscribe_to_channels(redis_host, redis_port, exchanges, symbols, use_ssl):
    conn = None
    try:
        url = f"rediss://{redis_host}:{redis_port}" if use_ssl else f"redis://{redis_host}:{redis_port}"
        conn = await aioredis.from_url(url, decode_responses=True)

        pubsub = conn.pubsub()
        channels = []
        for exchange in exchanges:
            for symbol in symbols:
                for data_type in ['book', 'trades']:
                    channel_name = f"{data_type}-{exchange}-{symbol}"
                    channels.append(channel_name)

        # Subscribe to all channels
        await pubsub.subscribe(*channels)

        # Create a task to handle incoming messages for each channel
        tasks = []
        while True:
            message = await pubsub.get_message(ignore_subscribe_messages=True)
            if message:
                print(f"Received message on channel {message['channel']}: {message['data']}")

    except Exception as e:
        print(f"Error subscribing to channels: {e}")
    finally:
        if conn:
            try:
                await conn.aclose()
            except AttributeError as e:
                print(f"Attribute Error closing connection: {e}")



async def handle_channel_messages(channel):
    while await channel.wait_message():
        message = await channel.get(encoding='utf-8')
        print(f"Received message on channel {channel.name}: {message}")

async def main():
    redis_host = "redis-0001-001.redis.tetmd7.apne1.cache.amazonaws.com"
    redis_port = 6379
    ssl_enabled = True
    symbols = config['bn_symbols']
    exchanges = ['BITFINEX', 'BINANCE']
    r = None
    try:
    # Assuming add_and_check_key is synchronous
        #await add_and_check_key(redis_host, redis_port, 'test_key', 'test_value', use_ssl=ssl_enabled)
        #await test_redis_connection(host=redis_host, port=redis_port, use_ssl=ssl_enabled)
        print('Create Redis client')
        tasks = [
            check_last_update(redis_host, redis_port, exchanges, symbols, use_ssl=ssl_enabled),
            subscribe_to_channels(redis_host, redis_port, exchanges, symbols, use_ssl=ssl_enabled)
        ]
        await asyncio.gather(*tasks)
    except Exception as e:
        print(f"An error occurred: {e}")
    finally:
        if r:
            await r.aclose()
        
if __name__ == "__main__":
    asyncio.run(main())
    #version2
