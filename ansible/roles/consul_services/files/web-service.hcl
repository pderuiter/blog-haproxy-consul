service {
  name = "web"
  port = 8080
  tags = ["http", "production"]
  
  meta {
    version = "1.0.0"
    environment = "production"
  }
  
  # More than one check: use a "checks" list, repeated check blocks fail to parse
  checks = [
    {
      name = "HTTP Health Check"
      http = "http://localhost:8080/health"
      interval = "10s"
      timeout = "5s"
      
      success_before_passing = 2
      failures_before_critical = 3
    },
    {
      name = "TCP Port Check"
      tcp = "localhost:8080"
      interval = "5s"
      timeout = "2s"
    }
  ]
}
