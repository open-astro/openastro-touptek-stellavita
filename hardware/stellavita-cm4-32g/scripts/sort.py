import re
import sys
import csv

# 读取原始数据文件
def read_wifi_data(file_path, wifi_band):
    with open(file_path, 'r', encoding='utf-8') as file:
        lines = file.readlines()

    header = [h.strip() for h in lines[0].split()]
    data = []
    fields_to_keep = ['bssid', 'ch', 'RSSI', 'ssid', 'flag']

    for line in lines[1:]:
        parts = line.strip().split()
        if len(parts) >= len(header):
            entry_dict = {}
            for i, header_field in enumerate(header):
                if header_field == 'ssid':  
                    ssid_value = ' '.join(parts[9:])
                    entry_dict['ssid'] = ssid_value
                elif header_field in fields_to_keep:
                    entry_dict[header_field] = parts[i]
            if wifi_band == '2.4':
                if 'ch' in entry_dict and int(entry_dict['ch']) <= 14:
                    data.append(entry_dict)
            elif wifi_band == '5':
                if 'ch' in entry_dict and int(entry_dict['ch']) >= 14:
                    data.append(entry_dict)

    return data

# 去除ssid空白字段和排序
def filter_and_sort_wifi_data(data):
    seen_ssids = set()
    filtered_data = []

    for entry in data:
        ssid = entry.get('ssid', '')
        if all(entry.get(field) for field in ['bssid', 'RSSI', 'ssid', 'flag']):
            seen_ssids.add(ssid)
            filtered_data.append(entry)

    sorted_data = sorted(filtered_data, key=lambda x: int(x['RSSI']), reverse=True)
    return sorted_data

def main():
    file_path = '/tmp/wifi_networks.txt'
    if len(sys.argv) != 2:
        print("Usage: python sort.py <wifi_band>")
        sys.exit(1)
    wifi_band = str(sys.argv[1])

    data = read_wifi_data(file_path, wifi_band)
    filtered_data = filter_and_sort_wifi_data(data)

    for entry in filtered_data:
        if 'flag' in entry:  # 检查是否存在flag字段
            if 'WPA' in entry['flag'] or 'WEP' in entry['flag']:  # 检查flag是否包含WPA或WEP
                entry['flag'] = 'true'  # 如果包含则替换为true
            else:
                entry['flag'] = 'false'  # 如果不包含则替换为false

    # Write the result to output.txt
    with open(file_path, 'w', encoding='utf-8') as output_file:
        header = ['bssid', 'RSSI', 'flag', 'ssid']
        output_file.write('\t'.join(header) + '\n')  # Write header to file
        for entry in filtered_data:
            output_file.write('\t'.join(str(entry.get(field, '')) for field in header) + '\n')
        

if __name__ == "__main__":
    main()
