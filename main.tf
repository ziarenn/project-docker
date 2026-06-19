terraform {
  required_version = ">= 1.3.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
}

locals {
  # Globally unique suffix so ACR / SQL / Web App names don't collide.
  suffix         = random_string.suffix.result
  location       = "swedencentral"
  sql_admin_user = "sqladmin"
  docker_image   = "iot-app:latest"
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

# Zero Hardcoded Credentials: the SQL password is generated at apply time
# and never written into the application code or container image.
resource "random_password" "sql" {
  length = 24
  # Restrict the special-character set to symbols that are safe inside
  # SQL Server passwords and connection strings.
  special          = true
  override_special = "_%@#"
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-iot-${local.suffix}"
  location = local.location
}

# ---------------------------------------------------------------------------
# Azure SQL (Server + Database, Basic tier) + firewall for Azure services
# ---------------------------------------------------------------------------
resource "azurerm_mssql_server" "sql" {
  name                         = "sql-iot-${local.suffix}"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = azurerm_resource_group.rg.location
  version                      = "12.0"
  administrator_login          = local.sql_admin_user
  administrator_login_password = random_password.sql.result
}

resource "azurerm_mssql_database" "db" {
  name      = "iotdb"
  server_id = azurerm_mssql_server.sql.id
  sku_name  = "Basic"
}

# Allow access from Azure services (App Service) to the SQL Server.
resource "azurerm_mssql_firewall_rule" "allow_azure" {
  name             = "AllowAllWindowsAzureIps"
  server_id        = azurerm_mssql_server.sql.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# ---------------------------------------------------------------------------
# Azure Container Registry (Basic). Admin user is DISABLED: the Web App pulls
# the image using its System-Assigned Managed Identity + AcrPull role instead.
# ---------------------------------------------------------------------------
resource "azurerm_container_registry" "acr" {
  name                = "acriot${local.suffix}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = false
}

# ---------------------------------------------------------------------------
# App Service Plan (Linux, F1 Free tier)
# ---------------------------------------------------------------------------
# NOTE: The F1 Free tier does NOT support custom Docker containers on Linux
# (custom containers require B1 or higher). The plan below uses "F1" exactly
# as required. To make the container deployment actually run, change the
# single line to: sku_name = "B1"
resource "azurerm_service_plan" "plan" {
  name                = "asp-iot-${local.suffix}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "F1"
}

# ---------------------------------------------------------------------------
# Linux Web App pulling the image from ACR via Managed Identity.
# Only the SQL secrets are injected as env vars (Zero Hardcoded Credentials);
# no ACR credentials are stored anywhere.
# ---------------------------------------------------------------------------
resource "azurerm_linux_web_app" "app" {
  name                = "app-iot-${local.suffix}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  service_plan_id     = azurerm_service_plan.plan.id

  # System-Assigned Managed Identity used to authenticate against ACR.
  identity {
    type = "SystemAssigned"
  }

  site_config {
    # F1 Free tier does not support "always on".
    always_on = false

    # Pull the container image using the Managed Identity instead of credentials.
    container_registry_use_managed_identity = true

    application_stack {
      docker_image_name   = local.docker_image
      docker_registry_url = "https://${azurerm_container_registry.acr.login_server}"
    }
  }

  app_settings = {
    # Continuous Deployment webhook for the container image.
    DOCKER_ENABLE_CI = "true"

    # The app listens on 8080; tell App Service to route traffic there.
    WEBSITES_PORT = "8080"

    # Database credentials injected dynamically from Terraform resources.
    DB_SERVER   = azurerm_mssql_server.sql.fully_qualified_domain_name
    DB_NAME     = azurerm_mssql_database.db.name
    DB_USER     = local.sql_admin_user
    DB_PASSWORD = random_password.sql.result
  }
}

# ---------------------------------------------------------------------------
# Grant the Web App's Managed Identity permission to pull from ACR (AcrPull).
# ---------------------------------------------------------------------------
resource "azurerm_role_assignment" "acr_pull" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_linux_web_app.app.identity[0].principal_id
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "web_app_url" {
  value = "https://${azurerm_linux_web_app.app.default_hostname}"
}

output "acr_login_server" {
  value = azurerm_container_registry.acr.login_server
}

output "sql_server_fqdn" {
  value = azurerm_mssql_server.sql.fully_qualified_domain_name
}

output "sql_admin_password" {
  value     = random_password.sql.result
  sensitive = true
}
