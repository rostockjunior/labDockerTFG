-- Create a sample database and user for the web application

CREATE DATABASE IF NOT EXISTS webapp;

CREATE USER IF NOT EXISTS 'webuser'@'192.168.4.%' IDENTIFIED BY 'webpass';
GRANT ALL PRIVILEGES ON webapp.* TO 'webuser'@'192.168.4.%';

FLUSH PRIVILEGES;

USE webapp;

CREATE TABLE IF NOT EXISTS visits (
    id INT AUTO_INCREMENT PRIMARY KEY,
    source_ip VARCHAR(45) NOT NULL,
    visited_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
