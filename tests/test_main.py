from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_root_endpoint():
    response = client.get("/")
    assert response.status_code == 200
    body = response.json()
    assert body["success"] is True
    assert body["statusCode"] == 200
    assert "service" in body["data"]
    assert body["data"]["status"] == "running"
    assert "X-Request-ID" in response.headers


def test_health_endpoint():
    response = client.get("/health")
    assert response.status_code in [200, 503]
    body = response.json()
    assert "status" in body["data"]
    assert "environment" in body["data"]
    assert "X-Request-ID" in response.headers


def test_v1_health_endpoint():
    response = client.get("/api/v1/health")
    assert response.status_code in [200, 503]
    body = response.json()
    assert "status" in body["data"]
    assert "X-Request-ID" in response.headers


def test_frontend_html_rendering():
    """Verify that browser requests with Accept: text/html receive the Jinja2 rendered HTML UI."""
    response = client.get("/", headers={"Accept": "text/html,application/xhtml+xml"})
    assert response.status_code == 200
    assert "text/html" in response.headers["content-type"]
    assert "DocuExtract" in response.text
    assert "dropZone" in response.text
    assert "btnProcess" in response.text
    assert "btnCancelProcessing" in response.text
    assert "resultSection" in response.text


def test_static_css_and_js_served():
    """Verify that static CSS and JavaScript files are mounted and served correctly."""
    css_resp = client.get("/static/css/style.css")
    assert css_resp.status_code == 200
    assert "text/css" in css_resp.headers["content-type"]
    assert "--color-canvas" in css_resp.text
    assert "#EDEBE4" in css_resp.text
    assert "#1D4ED8" in css_resp.text

    js_resp = client.get("/static/js/app.js")
    assert js_resp.status_code == 200
    assert "javascript" in js_resp.headers["content-type"]
    assert "DocuExtract" in js_resp.text
    assert "MAX_POLL_ATTEMPTS: null" in js_resp.text
    assert "btnCancelProcessing" in js_resp.text
