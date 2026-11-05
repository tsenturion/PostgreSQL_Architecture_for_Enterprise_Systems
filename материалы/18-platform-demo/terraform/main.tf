terraform {
  required_version = "= 1.16.6"
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "4.6.0"
    }
  }
}

provider "docker" {
  host = "unix:///var/run/docker.sock"
}

variable "request" {
  description = "Заявка на учебную базу"
  type = object({
    service = string
    team    = string
    profile = string
  })
  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{1,19}$", var.request.service)) && can(regex("^[a-z][a-z0-9-]{1,23}$", var.request.team))
    error_message = "Укажите короткие имена сервиса и команды в нижнем регистре."
  }
  validation {
    condition     = contains(["sandbox", "integration"], var.request.profile)
    error_message = "Выберите профиль sandbox или integration."
  }
}

locals {
  profiles = {
    sandbox     = { memory_mb = 384, cpu = "0.5", timeout = "2s" }
    integration = { memory_mb = 512, cpu = "0.75", timeout = "4s" }
  }
  profile  = local.profiles[var.request.profile]
  db_name  = "svc_${var.request.service}"
  root_dir = abspath("${path.root}/..")
}

data "docker_image" "postgres" {
  name = "pg-course-local:18"
}

resource "docker_volume" "data" {
  name = "pg-course-platform18-data"
  labels {
    label = "pg-course.lesson"
    value = "18"
  }
}

resource "docker_container" "postgres" {
  name                  = "pg-course-platform18"
  image                 = data.docker_image.postgres.id
  memory                = local.profile.memory_mb
  memory_swap           = local.profile.memory_mb
  cpus                  = local.profile.cpu
  shm_size              = 128
  remove_volumes        = false
  log_driver            = "none"
  stop_signal           = "SIGINT"
  destroy_grace_seconds = 45
  entrypoint            = ["/bin/bash", "/run/platform/start-postgres.sh"]
  env = [
    "PGDATA=/var/lib/postgresql/18/docker",
    "POSTGRES_PASSWORD_FILE=/run/platform/admin-password"
  ]
  ports {
    internal = 5432
    external = 15435
    ip       = "127.0.0.1"
  }
  volumes {
    volume_name    = docker_volume.data.name
    container_path = "/var/lib/postgresql"
  }
  volumes {
    host_path      = "${local.root_dir}/.secrets/admin"
    container_path = "/run/platform/admin-password"
    read_only      = true
  }
  volumes {
    host_path      = "${local.root_dir}/start-postgres.sh"
    container_path = "/run/platform/start-postgres.sh"
    read_only      = true
  }
  volumes {
    host_path      = "/opt/pg-course/logs/platform18"
    container_path = "/var/log/course"
  }
  labels {
    label = "pg-course.lesson"
    value = "18"
  }
  labels {
    label = "platform.team"
    value = var.request.team
  }
}

output "contract" {
  description = "Описание подключения и управляемых объектов для Ansible"
  value = {
    platform = {
      host              = "127.0.0.1"
      port              = one(docker_container.postgres.ports).external
      database          = local.db_name
      owner             = "${local.db_name}_owner"
      login             = "${local.db_name}_app"
      schema            = "app"
      statement_timeout = local.profile.timeout
      team              = var.request.team
    }
  }
}
