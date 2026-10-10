variable "contracts" {
  description = "platform-db-* contracts keyed by a short name (postgresql, mysql, sql, sqlmi, sqlvm, ...); null = not deployed. Only `dbm` is read."
  type        = any
}

variable "base_path" {
  description = "DSV base path of the environment (foundation-identity contract secrets.base_path), e.g. eh/dev."
  type        = string
}

variable "identity_client_id" {
  description = "Client id of the DBM identity (Entra database login) when a contract does not publish one."
  type        = string
}

variable "entra_username" {
  description = "Database user name of the DBM identity when a contract does not publish identity_name."
  type        = string
  default     = "obs-dbm"
}
