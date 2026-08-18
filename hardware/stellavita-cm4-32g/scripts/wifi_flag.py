import sqlite3
import sys

# 数据库文件路径
db_file = '/home/pi/.as/config/global.db'
flag_name = str(sys.argv[1])
# 连接到SQLite数据库
conn = sqlite3.connect(db_file)
cursor = conn.cursor()

# 执行SQL查询，获取 WifiBridgingOn 的值
sql = "SELECT Value FROM Global WHERE Key = '%s';" %(flag_name)
cursor.execute(sql)
result = cursor.fetchone()

# 如果查询到结果，输出值
if result:
    print(result[0])

# 关闭数据库连接
conn.close()