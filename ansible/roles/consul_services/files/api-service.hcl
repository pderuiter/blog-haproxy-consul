service {
  name = "api"
  port = 3000
  tags = ["http", "api", "v2"]
  
  weights {
    passing = 100
    warning = 50
  }
  
  check {
    name = "API Health"
    http = "http://localhost:3000/api/health"
    interval = "10s"
    timeout = "3s"
    header {
      Content-Type = ["application/json"]
    }
  }
}
