-- dbtool 結合テスト用スキーマ (root で実行)
SET GLOBAL log_bin_trust_function_creators = 1;
DROP DATABASE IF EXISTS perf;
DROP DATABASE IF EXISTS perf_restore;
CREATE DATABASE perf CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE perf_restore CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE perf;

CREATE TABLE categories (
  id         INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  code       VARCHAR(10) NOT NULL,
  name       VARCHAR(50) NOT NULL COMMENT 'カテゴリ名',
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uk_code (code)
) COMMENT='商品カテゴリ';

CREATE TABLE customers (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  email       VARCHAR(255) NOT NULL,
  name        VARCHAR(100) NOT NULL COMMENT '氏名',
  kana        VARCHAR(100) NULL,
  tel         VARCHAR(20) NULL,
  zip         CHAR(8) NULL,
  status      ENUM('active','suspended','closed') NOT NULL DEFAULT 'active',
  points      INT NOT NULL DEFAULT 0,
  birthday    DATE NULL,
  last_login  TIMESTAMP(3) NULL,
  is_vip      TINYINT(1) NOT NULL DEFAULT 0,
  memo        TEXT NULL,
  uuid        CHAR(36) NOT NULL,
  created_at  DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at  TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uk_email (email),
  UNIQUE KEY uk_uuid (uuid),
  KEY idx_status (status)
) COMMENT='顧客';

CREATE TABLE products (
  product_code CHAR(10) NOT NULL PRIMARY KEY,
  category_id  INT NOT NULL,
  name         VARCHAR(200) NOT NULL,
  price        DECIMAL(10,2) NOT NULL,
  weight       FLOAT NULL,
  tags         SET('new','sale','limited') NULL,
  attrs        JSON NULL,
  image        VARBINARY(64) NULL,
  flags        BIT(8) NOT NULL DEFAULT b'0',
  location     POINT SRID 4326 NULL,
  CONSTRAINT chk_price CHECK (price >= 0),
  KEY idx_cat (category_id),
  CONSTRAINT fk_prod_cat FOREIGN KEY (category_id) REFERENCES categories (id)
);

CREATE TABLE orders (
  order_id    BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  customer_id BIGINT UNSIGNED NOT NULL,
  order_no    VARCHAR(20) NOT NULL,
  ordered_at  DATETIME NOT NULL,
  total       DECIMAL(12,2) NOT NULL,
  status      VARCHAR(10) NOT NULL,
  note        VARCHAR(255) NULL,
  total_tax   DECIMAL(12,2) AS (total * 0.1) STORED,
  UNIQUE KEY uk_order_no (order_no),
  KEY idx_cust (customer_id, ordered_at),
  CONSTRAINT fk_ord_cust FOREIGN KEY (customer_id) REFERENCES customers (id)
);

CREATE TABLE order_items (
  order_id     BIGINT NOT NULL,
  line_no      SMALLINT NOT NULL,
  product_code CHAR(10) NOT NULL,
  qty          INT NOT NULL,
  unit_price   DECIMAL(10,2) NOT NULL,
  PRIMARY KEY (order_id, line_no),
  CONSTRAINT fk_item_ord FOREIGN KEY (order_id) REFERENCES orders (order_id),
  CONSTRAINT fk_item_prod FOREIGN KEY (product_code) REFERENCES products (product_code)
);

CREATE TABLE roles (
  id        INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  role_name VARCHAR(30) NOT NULL,
  UNIQUE KEY uk_role (role_name)
);

CREATE TABLE user_roles (
  user_id BIGINT UNSIGNED NOT NULL,
  role_id INT NOT NULL,
  granted_at DATETIME NOT NULL,
  PRIMARY KEY (user_id, role_id),
  CONSTRAINT fk_ur_user FOREIGN KEY (user_id) REFERENCES customers (id),
  CONSTRAINT fk_ur_role FOREIGN KEY (role_id) REFERENCES roles (id)
);

CREATE TABLE employees (
  id         INT NOT NULL PRIMARY KEY,
  manager_id INT NULL,
  boss_id    INT NOT NULL,
  name       VARCHAR(50) NOT NULL,
  CONSTRAINT fk_emp_mgr FOREIGN KEY (manager_id) REFERENCES employees (id),
  CONSTRAINT fk_emp_boss FOREIGN KEY (boss_id) REFERENCES employees (id)
);

-- 複合外部キー
CREATE TABLE shops (
  region_cd CHAR(2) NOT NULL,
  shop_no   INT NOT NULL,
  shop_name VARCHAR(50) NOT NULL,
  PRIMARY KEY (region_cd, shop_no)
);
CREATE TABLE shop_sales (
  id        INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  region_cd CHAR(2) NOT NULL,
  shop_no   INT NOT NULL,
  sold_on   DATE NOT NULL,
  amount    INT NOT NULL,
  CONSTRAINT fk_ss_shop FOREIGN KEY (region_cd, shop_no) REFERENCES shops (region_cd, shop_no)
);

-- 文字コード・照合順序
CREATE TABLE legacy (
  id      INT NOT NULL PRIMARY KEY,
  code_ci VARCHAR(12) CHARACTER SET latin1 COLLATE latin1_swedish_ci NOT NULL,
  sj      VARCHAR(20) CHARACTER SET cp932 NULL,
  bin16   BINARY(16) NOT NULL,
  inv     INT NULL INVISIBLE,
  UNIQUE KEY uk_code_ci (code_ci),
  UNIQUE KEY uk_bin16 (bin16)
);

-- 全データ型 (export/import の往復検証用)
CREATE TABLE all_types (
  id INT PRIMARY KEY,
  s VARCHAR(100), t TEXT, c CHAR(5),
  f FLOAT, d DOUBLE, dec1 DECIMAL(30,10), ubig BIGINT UNSIGNED, sbig BIGINT,
  b VARBINARY(20), fb BINARY(4), bl MEDIUMBLOB,
  bt BIT(10), bt64 BIT(64),
  e ENUM('a','b,c','d"e'), st SET('x','y','z'),
  j JSON,
  dt DATETIME(6), ts TIMESTAMP(3) NULL, tm TIME(2), y YEAR, dd DATE,
  g POINT SRID 4326, geo GEOMETRY,
  gen INT AS (id*2) VIRTUAL,
  lat1 VARCHAR(20) CHARACTER SET latin1,
  sj VARCHAR(20) CHARACTER SET cp932
);

DELIMITER //
CREATE TRIGGER trg_orders_bi BEFORE INSERT ON orders FOR EACH ROW
BEGIN
  IF NEW.note IS NULL THEN SET NEW.note = 'by-trigger'; END IF;
END//
DELIMITER ;

CREATE VIEW v_orders AS SELECT o.order_id, o.order_no, c.email FROM orders o JOIN customers c ON c.id = o.customer_id;

CREATE PROCEDURE perf.p_count() SELECT COUNT(*) FROM perf.orders;

GRANT ALL ON perf.* TO 'admin'@'%';
GRANT ALL ON perf_restore.* TO 'admin'@'%';
