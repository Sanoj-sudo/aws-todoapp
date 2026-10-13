-- Database tier schema (MySQL 8 / Amazon RDS for MySQL / Aurora MySQL)
-- Run once against your RDS endpoint (from a bastion or an app-tier instance):
--   mysql -h <rds-endpoint> -u admin -p < database/schema.sql
-- (The API also creates these tables automatically on startup.)

CREATE DATABASE IF NOT EXISTS appdb;
USE appdb;

CREATE TABLE IF NOT EXISTS users (
  id             INT AUTO_INCREMENT PRIMARY KEY,
  name           VARCHAR(100) NOT NULL,
  email          VARCHAR(255) NOT NULL UNIQUE,
  password_hash  VARCHAR(255) NOT NULL,
  created_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS todos (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  user_id     INT NOT NULL,
  title       VARCHAR(255) NOT NULL,
  completed   BOOLEAN NOT NULL DEFAULT FALSE,
  created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_todos_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  INDEX idx_todos_user (user_id)
);

-- Optional: dedicated least-privilege user for the app tier
-- CREATE USER IF NOT EXISTS 'appuser'@'%' IDENTIFIED BY 'ChangeMe123!';
-- GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, INDEX, REFERENCES ON appdb.* TO 'appuser'@'%';
-- FLUSH PRIVILEGES;
