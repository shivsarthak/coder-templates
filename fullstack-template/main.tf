terraform {
   required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 0.6.17"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0.2"
    }
  }
}

locals {

    username        = data.coder_workspace.me.owner
    db_user         = "admin"
    db_password     = "password"
    backend_images ={
        redis = "redis:latest"
        mongodb = "mongo:latest"
        postgres = "postgres"
    }
    backend_path = {
        redis = "/data"
        mongodb = "/data/db"
        postgres = "/var/lib/postgresql/datar"
    }
}

provider "docker" {
}

data "coder_workspace" "me" {
}

data "coder_provisioner" "me" {
}

resource "coder_agent" "dev" {
    os                  = "linux"
    arch                = data.coder_provisioner.me.arch
    login_before_ready  = false
    startup_script         = <<-EOT
    set -e
    # install and start code-server
    curl -fsSL https://code-server.dev/install.sh | sh -s -- --method=standalone --prefix=/tmp/code-server --version 4.8.3
    /tmp/code-server/bin/code-server --auth none --port 13337 >/tmp/code-server.log 2>&1 &
  EOT
    env = {
        GIT_AUTHOR_NAME     = "${data.coder_workspace.me.owner}"
        GIT_COMMITTER_NAME  = "${data.coder_workspace.me.owner}"
        GIT_AUTHOR_EMAIL    = "${data.coder_workspace.me.owner_email}"
        GIT_COMMITTER_EMAIL = "${data.coder_workspace.me.owner_email}"
    }
}

resource "coder_app" "code-server" {
  agent_id     = coder_agent.dev.id
  slug         = "code-server"
  display_name = "Code Server"
  url          = "http://localhost:13337/?folder=/home/${local.username}"
  icon         = "/icon/code.svg"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 5
    threshold = 6
  }
}

data "coder_parameter" "database_type" {
  name        = "Database Type"
  description = "Which database do you want to use?"
  type        = "string"
  default     = "postgres"

  option {
    name        = "PostgreSQL"
    value       = "postgres"
    icon        = "https://uxwing.com/wp-content/themes/uxwing/download/brands-and-social-media/postgresql-icon.png"
  }
  option {
    name        = "MongoDB"
    value       = "mongodb"
    icon        = "https://cdn.iconscout.com/icon/free/png-256/mongodb-3521676-2945120.png"
  }
  option {
    name        = "Redis"
    value       = "redis"
    icon        = "https://cdn4.iconfinder.com/data/icons/redis-2/1451/Untitled-2-512.png"
  }
}


resource "docker_volume" "frontend_volume" {
    name                = "frontend-${data.coder_workspace.me.id}-volume"

    lifecycle {
        ignore_changes  = all
    }

     labels {
        label           = "coder.owner"
        value           = data.coder_workspace.me.owner
    }

    labels {
        label           = "coder.owner_id"
        value           = data.coder_workspace.me.owner_id
    }
}

resource "docker_volume" "backend_volume" {
    name                = "backend-${data.coder_workspace.me.id}-volume"

    lifecycle {
        ignore_changes  = all
    }

     labels {
        label           = "coder.owner"
        value           = data.coder_workspace.me.owner
    }

    labels {
        label           = "coder.owner_id"
        value           = data.coder_workspace.me.owner_id
    }
}



resource "docker_image" "backend_image" {
    name            = lookup(local.backend_images,data.coder_parameter.database_type.value)
}

resource "docker_image" "frontend_image" {
    name                = "next-frontend-image"
    build {
        context         = "./frontend"
        build_args = {
            USER        = local.username
        }
    }
}

resource "docker_network" "fullstack_network" {
  name              = "fullstack-${data.coder_workspace.me.id}-network"
}

resource "docker_container" "frontend" {
    count           = data.coder_workspace.me.transition == "start" ? 1 : 0
    name            = "fullstack-${data.coder_workspace.me.id}-frontend"
    image           = docker_image.frontend_image.image_id
    hostname = data.coder_workspace.me.name
    entrypoint = ["sh", "-c", replace(coder_agent.dev.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")]
    env        = ["CODER_AGENT_TOKEN=${coder_agent.dev.token}"]
    host {
        host = "host.docker.internal"
        ip   = "host-gateway"
    }
    networks_advanced  {
        name        = docker_network.fullstack_network.id
    }

    volumes {
        container_path = "/home/${local.username}"
        volume_name    = docker_volume.frontend_volume.name
        read_only      = false
    }
}

resource "docker_container" "backend" {
    count           = data.coder_workspace.me.start_count
    name            = "fullstack-${data.coder_workspace.me.id}-backend"
    image           = docker_image.backend_image.image_id
    
    networks_advanced  {
        name        = docker_network.fullstack_network.id
    }

    mounts {
        type        = "volume"
        target      = lookup( local.backend_path,data.coder_parameter.database_type.value)
        source      = docker_volume.backend_volume.name
    }

    env = [
        "POSTGRES_PASSWORD=${local.db_password}",
        "POSTGRES_USER=${local.db_user}",
        "MONGO_INITDB_ROOT_USERNAME=${local.db_password}",
        "MONGO_INITDB_ROOT_PASSWORD=${local.db_user}"
    ]
}

resource "coder_metadata" "backend_info" {
    count           = data.coder_workspace.me.start_count
    resource_id     = docker_container.backend[0].id
    item {
        key         = "IP"
        value       = docker_container.backend[0].network_data[0].ip_address
    }
    item {
        key         = "Database Type"
        value       = data.coder_parameter.database_type.value
    }
    item {
        key         = "Database Username"
        value       = local.db_user
    }
    item {
        key         = "Database Password"
        value       = local.db_password
    }
}
