"""Pub/Sub ports: per-subscriber SQLite offsets locally, SNS/SQS fan-out in AWS."""
import json, re
import urllib.request
from services.shared.persistence import Database

class SQLiteTopic:
    def __init__(self, url: str, subscribers: tuple[str, ...] = ("evidence", "operations")) -> None:
        self.database, self.subscribers = Database(url), subscribers
        self.database.migrate("broker.sql")
    def publish(self, message_id: str, payload: dict[str, object]) -> None:
        if not self.database.one("SELECT message_id FROM topic_messages WHERE message_id=?", (message_id,)):
            self.database.execute("INSERT INTO topic_messages (message_id, payload) VALUES (?, ?)", (message_id, json.dumps(payload, sort_keys=True)))
            for subscriber in self.subscribers: self.database.execute("INSERT INTO topic_deliveries (message_id, subscriber) VALUES (?, ?)", (message_id, subscriber))
    def receive(self, subscriber: str) -> list[tuple[str, dict[str, object]]]:
        rows = self.database.all("SELECT d.message_id, m.payload FROM topic_deliveries d JOIN topic_messages m ON m.message_id=d.message_id WHERE d.subscriber=? AND d.acknowledged_at IS NULL ORDER BY d.message_id LIMIT 10", (subscriber,))
        return [(row[0], json.loads(row[1])) for row in rows]
    def acknowledge(self, subscriber: str, receipt: str) -> None:
        self.database.execute("UPDATE topic_deliveries SET acknowledged_at=CURRENT_TIMESTAMP WHERE message_id=? AND subscriber=?", (receipt, subscriber))

class SnsTopic:
    def __init__(self, topic_arn: str) -> None:
        import boto3
        self.topic_arn, self.client = topic_arn, boto3.client("sns")
    def publish(self, message_id: str, payload: dict[str, object]) -> None:
        self.client.publish(TopicArn=self.topic_arn, Message=json.dumps(payload, sort_keys=True), MessageGroupId="evidence", MessageDeduplicationId=message_id)

class SqsSubscription:
    def __init__(self, queue_url: str) -> None:
        import boto3
        self.queue_url, self.client = queue_url, boto3.client("sqs")
    def receive(self, subscriber: str) -> list[tuple[str, dict[str, object]]]:
        response = self.client.receive_message(QueueUrl=self.queue_url, MaxNumberOfMessages=10, WaitTimeSeconds=10)
        result = []
        for item in response.get("Messages", []):
            result.append((item["ReceiptHandle"], parse_sqs_body(item["Body"])))
        return result
    def acknowledge(self, subscriber: str, receipt: str) -> None: self.client.delete_message(QueueUrl=self.queue_url, ReceiptHandle=receipt)

def parse_sqs_body(body: str) -> dict[str, object]:
    decoded = json.loads(body)
    if isinstance(decoded, dict) and "Message" in decoded:
        message = decoded["Message"]
        return json.loads(message) if isinstance(message, str) else message
    if not isinstance(decoded, dict): raise ValueError("Pub/Sub message must be a JSON object")
    return decoded

class HttpTopic:
    def __init__(self, url: str, token: str) -> None: self.url, self.token = url.rstrip("/"), token
    def request(self, method: str, path: str, body=None):
        request = urllib.request.Request(self.url + path, data=json.dumps(body).encode() if body is not None else None, method=method, headers={"Content-Type": "application/json", "X-Service-Token": self.token})
        with urllib.request.urlopen(request, timeout=10) as response: return json.load(response)
    def publish(self, message_id, payload): self.request("POST", "/messages", {"message_id": message_id, "payload": payload})
    def receive(self, subscriber): return [(item[0], item[1]) for item in self.request("GET", f"/subscriptions/{subscriber}")["messages"]]
    def acknowledge(self, subscriber, receipt): self.request("POST", f"/subscriptions/{subscriber}", {"receipt": receipt})

def publisher_from_url(url: str, token: str = ""):
    if url.startswith("sqlite:///"): return SQLiteTopic(url)
    if url.startswith("http://") or url.startswith("https://"): return HttpTopic(url, token)
    if re.fullmatch(r"arn:aws:sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_.-]+\.fifo", url): return SnsTopic(url)
    raise ValueError("BROKER_TOPIC must be SQLite or an SNS topic ARN")

def subscriber_from_url(url: str, token: str = ""):
    if url.startswith("sqlite:///"): return SQLiteTopic(url)
    if url.startswith("https://sqs.") or url.startswith("https://sqs-"):
        if re.fullmatch(r"https://sqs[.-][a-z0-9-]+\.amazonaws\.com/[0-9]{12}/[A-Za-z0-9_.-]+\.fifo", url): return SqsSubscription(url)
        raise ValueError("BROKER_SUBSCRIPTION must be a valid FIFO SQS queue URL")
    if url.startswith("http://") or url.startswith("https://"): return HttpTopic(url, token)
    raise ValueError("BROKER_SUBSCRIPTION must be SQLite or an SQS queue URL")
