FROM python:3.12-alpine

WORKDIR /app

COPY webhook-receiver.py .

EXPOSE 8080

CMD ["python", "webhook-receiver.py"]
