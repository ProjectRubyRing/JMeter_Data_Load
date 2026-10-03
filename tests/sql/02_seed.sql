-- 初期データ (prepare 前の状態。cleanup 後にこの状態へ戻ることを検証する)
USE perf;
SET time_zone = '+09:00';
INSERT INTO categories (id, code, name, created_at) VALUES
 (1, 'FOOD', '食品', '2025-01-01 10:00:00'), (2, 'BOOK', '書籍', '2025-01-02 10:00:00'), (5, 'TOY', 'おもちゃ', NULL);
INSERT INTO customers (id, email, name, kana, tel, zip, status, points, birthday, last_login, is_vip, memo, uuid, created_at, updated_at) VALUES
 (1, 'taro@example.jp', '山田太郎', 'ヤマダタロウ', '03-1234-5678', '100-0001', 'active', 100, '1990-04-01', '2026-01-02 03:04:05.678', 1, 'メモ "引用" \\ バックスラッシュ\n改行', '11111111-1111-4111-8111-111111111111', '2025-05-05 05:05:05.123456', '2025-05-05 05:05:05'),
 (2, 'hanako@example.jp', '佐藤花子', NULL, NULL, NULL, 'suspended', 0, NULL, NULL, 0, NULL, '22222222-2222-4222-8222-222222222222', '2025-06-06 06:06:06.000001', NULL),
 (7, 'emoji@example.jp', '絵文字😀', 'エモジ', NULL, NULL, 'closed', -5, '2000-02-29', '2038-01-19 12:14:07.999', 0, '', '77777777-7777-4777-8777-777777777777', '2025-07-07 07:07:07', '2026-07-07 07:07:07');
ALTER TABLE customers AUTO_INCREMENT = 100;
INSERT INTO products (product_code, category_id, name, price, weight, tags, attrs, image, flags, location) VALUES
 ('P000000001', 1, 'りんご', 120.00, 0.3, 'new,sale', '{"color": "red", "size": [1, 2]}', X'00FF10', b'10100101', ST_GeomFromText('POINT(35.68 139.76)', 4326)),
 ('P000000002', 2, '本', 1980.50, NULL, '', NULL, NULL, b'0', NULL);
INSERT INTO orders (order_id, customer_id, order_no, ordered_at, total, status, note) VALUES
 (1, 1, 'ORD-0001', '2026-01-01 12:00:00', 2100.50, 'paid', NULL), (2, 2, 'ORD-0002', '2026-01-02 13:00:00', 120.00, 'new', 'メモ');
INSERT INTO order_items VALUES (1, 1, 'P000000001', 1, 120.00), (1, 2, 'P000000002', 1, 1980.50), (2, 1, 'P000000001', 1, 120.00);
INSERT INTO roles (id, role_name) VALUES (1, 'admin'), (2, 'user'), (3, 'guest');
INSERT INTO user_roles VALUES (1, 1, '2026-01-01 00:00:00'), (1, 2, '2026-01-01 00:00:00'), (2, 2, '2026-01-01 00:00:00');
INSERT INTO employees VALUES (1, NULL, 1, '社長'), (2, 1, 1, '部長');
INSERT INTO shops VALUES ('JP', 1, '東京店'), ('JP', 2, '大阪店'), ('US', 1, 'NY');
INSERT INTO shop_sales (region_cd, shop_no, sold_on, amount) VALUES ('JP', 1, '2026-01-01', 1000);
INSERT INTO legacy (id, code_ci, sj, bin16, inv) VALUES (1, 'ABC', 'ﾃｽﾄ漢字', UUID_TO_BIN('11111111-1111-4111-8111-111111111111'), 9);

SET time_zone = '+09:00';
INSERT INTO all_types (id,s,t,c,f,d,dec1,ubig,sbig,b,fb,bl,bt,bt64,e,st,j,dt,ts,tm,y,dd,g,geo,lat1,sj) VALUES
(1, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
(2, '', '', '', 0, 0, 0, 0, 0, '', X'00000000', '', b'0', b'0', 'a', '', 'null', '1000-01-01 00:00:00', '1970-01-01 09:00:01', '-838:59:59', 1901, '1000-01-01', ST_GeomFromText('POINT(35.6 139.7)', 4326), ST_GeomFromText('LINESTRING(0 0,1 1,2.5 3.25)'), '', ''),
(3, 'NULL', '\\N', 'N', 0.1, 0.30000000000000004, 12345678901234567890.0123456789, 18446744073709551615, -9223372036854775808, X'5C2C220A0D0900', X'5C2C220A', X'00FF5C0A', b'1111111111', b'1111111111111111111111111111111111111111111111111111111111111111', 'b,c', 'x,z', '{"k": "v\\"q\\\\b\\n", "n": [1, 2.5, null, true], "jp": "日本語🍣"}', '9999-12-31 23:59:59.999999', '2038-01-19 12:14:07.999', '838:59:59', 2155, '9999-12-31', ST_GeomFromText('POINT(-90 180)', 4326), ST_GeomFromText('POLYGON((0 0,10 0,10 10,0 10,0 0))'), CONCAT('caf', X'E9'), 'ｱｲｳ表示'),
(4, 'a"b""c', 'line1\nline2\r\nline3\tTAB', 'ab  ', 3.4028234e38, 1.7976931348623157e308, -0.0000000001, 1, 9223372036854775807, X'', X'01', NULL, b'1010101010', b'1', 'd"e', 'x,y,z', '[]', '2026-10-04 12:34:56.000001', '2026-10-04 12:34:56.5', '-00:00:00.01', 2026, '2026-10-04', NULL, NULL, 'x,y', '①②'),
(5, 'back\\slash\\\\end\\', 'NUL:\0:after', 'Z', 1.17549435e-38, 5e-324, 99999999999999999999.9999999999, 9007199254740993, -9007199254740993, X'FFFFFFFF', X'FFFFFFFF', REPEAT(X'AB', 70000), b'1000000000', b'1000000000000000000000000000000000000000000000000000000000000000', NULL, NULL, '"just a string"', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
(6, '  lead and trail  ', '絵文字😀👨‍👩‍👧 4byte', '日本語', -1.5, -2.2250738585072014e-308, 0.5, 42, -42, X'2C', X'2C2C2C2C', X'2C', b'11', b'11', 'a', 'y', '{"a":{"b":{"c":[1,{"d":"e"}]}}}', '2026-01-01 00:00:00', '2026-03-29 01:30:00', '12:00:00', 2000, '2000-02-29', ST_GeomFromText('POINT(0 0)', 4326), ST_GeomFromText('MULTIPOINT((1 1),(2 2))'), 'tab\there', 'ﾃｽﾄ'),
(7, 'comma,inside', 'CR\ronly', ',', 123.456, 1e100, -99999999999999999999.9999999999, 0, 0, X'0A', X'0D0A0D0A', X'22', b'0', b'0', 'a', 'x', '{"emptyobj":{}, "s":"\\u0000\\t"}', '2026-12-31 23:59:59', '2026-12-31 23:59:59', '00:00:00', 1999, '2026-12-31', ST_GeomFromText('POINT(1.0000000000000002 3.141592653589793)', 4326), ST_GeomFromText('GEOMETRYCOLLECTION(POINT(1 2),LINESTRING(0 0,1 1))'), 'naïve', '髙﨑');
