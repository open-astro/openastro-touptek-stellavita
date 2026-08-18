#!/bin/bash

# 检测本脚本的路径
script_path=$(dirname $(realpath $0))
script_path=$script_path"/"
wpa_conf=/etc/wpa_supplicant/wpa_supplicant.conf

# 检查是否有足够的参数
check_args() {
  if [ -z "$1" ]; then
    echo "error. no argument"
    exit 1
  fi
}

# 获取当前用作AP的网卡类型
get_ap_type() {
  wifi_interfaces=$(iw dev | awk '/Interface/{interface=$2}/type AP/{print interface}')
  if [[ $wifi_interfaces == *"aswlan"* ]]; then
    echo "external"
  else
    echo "internal"
  fi
  return 0
}

# 获取当前用作STA模式的网口名称
get_dstwlan() {
  wifi_interfaces=$(iw dev | awk '/Interface/{interface=$2}/type managed/{print interface}')
  counter=1
  while IFS= read -r line; do
    network_name=$(echo "$line" | awk '{print $1}')
    var_name="network_$counter"
    declare $var_name="$network_name"
    ((counter++))
  done <<< "$wifi_interfaces"
  echo $network_1
}

# 扫描可用的网络
scan_networks() {
  local wifi_file="/tmp/wifi_networks.txt"
  local ap_type=$(get_ap_type);
  if [[ "$ap_type" != "external" ]]; then
    echo "error. Not an operable network card."
    exit 1
  fi
  local wifi_iface=$(get_dstwlan);
  local sort_file="/usr/local/astrostation/bin/sort.py"
  local current_band=$(get_ap_band);
  supported_channels=
  if [[ "$current_band" == "5GHz" ]]; then
    supported_channels=5
  else
    supported_channels=2.4
  fi

  wifi_model="rtl88x2bu"
  USB_INFO=$(lsusb | grep "c820")
  if [ ! -z "$USB_INFO" ];then
    wifi_model="rtl8821cu"
  fi
  USB_INFO=$(lsusb | grep "c811")
  if [ ! -z "$USB_INFO" ];then
    wifi_model="rtl8821cu"
  fi
  # 检测是否成功获取到 Wi-Fi 列表
  local output=$(wpa_cli -i $wifi_iface scan)
  if [ $output == "OK" ]; then
    echo $output
    cat /proc/net/$wifi_model/$wifi_iface/survey_info | tee "$wifi_file" > /dev/null 2>&1 || true
    sync
    sudo python $sort_file $supported_channels
    sync
  else
    echo $output
    exit 1
  fi
  return 0
}

# 删除已有的WIFI配置
remove_wifi() {
  check_args "$1"
  local ap_type=$(get_ap_type);
  if [[ "$ap_type" != "external" ]]; then
    echo "error. Not an operable network card."
    exit 1
  fi
  local wifi_iface=$(get_dstwlan);
  local ssid="$1"
  local index=$(echo -e "$(wpa_cli -i $wifi_iface list_networks)" | awk -v name="$ssid" -F"\t" 'NR>1 && $2==name {print $1}')
  if [ -n "$index" ]; then
    wpa_cli remove_network "$index"
    echo "SSID exists, deleted"
  else
    echo "SSID doesn't exist"
    return 0
  fi
  wpa_cli save
  return 0
}

select_wifi() {
  check_args "$1"
  check_args "$2"
  local ap_type=$(get_ap_type);
  if [[ "$ap_type" != "external" ]]; then
    echo "error. Not an operable network card."：
    exit 1
  fi
  local wifi_iface=$(get_dstwlan);
  local ssid="$1"
  local bssid="$2"
  local index=$(echo -e "$(wpa_cli -i $wifi_iface list_networks)" | awk -v name="$ssid" -F"\t" 'NR>1 && $2==name {print $1}')
  if [ -n "$index" ]; then
    wpa_cli bssid "$index" $bssid
    wpa_cli save
    wpa_cli select_network "$index"
    echo "SSID exists, selected"
  else
    echo "SSID doesn't exist"
    exit -1
  fi
  wpa_cli save
  return 0
}

# 设置连接的SSID和密码
set_wifi() {
  check_args "$1"
  check_args "$2"
  local ssid="$1"
  password=
  bssid=
  if [ -z $3 ];then
    bssid=$2
  else
    password=$2
    bssid=$3
  fi
  
  local ap_type=$(get_ap_type);
  if [[ "$ap_type" != "external" ]]; then
    echo "error. Not an operable network card."
    exit 1
  fi
  local wifi_iface=$(get_dstwlan);
  
  if [ -z "$ssid" ];then
    echo "error. no ssid"
    exit 1
  fi

  #先删除相同名称的,避免出现名称相同但是密码不一致的情况
  remove_wifi "$ssid"
  if [ -z "$password" ];then
  sudo sh -c "cat >>$wpa_conf"<<EOF
network={
    ssid="$ssid"
    key_mgmt=NONE
}
EOF
  else
    pass_ret=$(wpa_passphrase "$ssid" "$password")
    #判断wpa_passphrase结果是否成功
    if [ $? -eq 0 ];then
      wpa_passphrase "$ssid" "$password" >> $wpa_conf
    else
      echo "error: $pass_ret"
      exit 1
    fi
  fi

  if [ ! 0 -eq $? ];then
    echo "error: write file fail"
    exit 1
  fi
  wpa_cli -i $wifi_iface reconfigure
  wpa_cli save
  #选择当前ssid
  select_wifi "$ssid" "$bssid"
  sync $wpa_conf
  return 0
}

# 获取当前连接状态
get_status() {
  local ap_type=$(get_ap_type);
  if [[ "$ap_type" != "external" ]]; then
    echo "error. Not an operable network card."
    exit 1
  fi
  local wifi_iface=$(get_dstwlan);
  # 获取当前的是否有连接WIFI
  local ret=$(iw $wifi_iface info | grep -E 'ssid|type managed')
  test -z "$ret"&&continue
  if [[ $ret =~ .*(ssid).* && $ret =~ .*(type managed).* ]]; then
    echo "connected"
    # 打印已连接的wifi信息
    echo -e "$(wpa_cli -i $wifi_iface status)" | grep -w ssid | awk -F'=' '{print "SSID: "$2}'
    ifconfig $wifi_iface | grep -w inet | awk '{print "IP: " $2}'
    ip route | grep $wifi_iface |grep default | awk '{print "GATEWAY: " $3}'
    ifconfig $wifi_iface | grep -w netmask | awk '{print "netmask: " $4}'
  else
    echo "disconnected"
  fi
}

# 断开当前的WIFI连接
disconnect_wifi() {
  local ap_type=$(get_ap_type);
  if [[ "$ap_type" != "external" ]]; then
    echo "error. Not an operable network card."
    exit 1
  fi
  local wifi_iface=$(get_dstwlan);

  if [ "$wifi_iface" != "wlan0" ]; then
    wpa_cli -i $wifi_iface disconnect
    # 保证板载和外接均无WIFI连接
    wpa_cli -i wlan0 disconnect
  else
    wpa_cli -i $wifi_iface disconnect
  fi
  return 0
}

# 恢复之前的WIFI连接
reconnect_wifi() {
  local ap_type=$(get_ap_type);
  if [[ "$ap_type" != "external" ]]; then
    echo "error. Not an operable network card."
    exit 1
  fi
  local wifi_iface=$(get_dstwlan);

  if [ "$wifi_iface" != "wlan0" ]; then
    wpa_cli -i $wifi_iface reconnect
  fi
  return 0
}

# 获取已经连接过的WIFI列表
get_list() {
  local ap_type=$(get_ap_type);
  if [[ "$ap_type" != "external" ]]; then
    echo "error. Not an operable network card."
    exit 1
  fi
  local wifi_iface=$(get_dstwlan);
  echo -e "$(wpa_cli -i $wifi_iface list_networks)" | awk -F"\t" 'NR>1{print $2}'
  return 0
}

# 设置当前AP的频段信息
set_ap_band() {
  check_args "$1"
  local HOSTAPDIR=/usr/local/astrostation/hostap
  local ap_bin="/usr/local/astrostation/bin/as_ap"
  local WLAN_FREQ=$1
  ap_type=$(get_ap_type);

  if [[ $WLAN_FREQ == "2.4" ]];then
    sudo ln -fs $HOSTAPDIR/as_2.4g.conf $HOSTAPDIR/as.conf
  elif [[ $WLAN_FREQ == "5" ]];then
    sudo ln -fs $HOSTAPDIR/as_5g.conf $HOSTAPDIR/as.conf
  fi
  sync
  $ap_bin

  if [[ "$ap_type" == "external" ]]; then
    wifi_iface=$(get_dstwlan);
    wpa_cli -i $wifi_iface disable_network all
    wpa_cli save
  fi
  sync
  return 0
}

# 获取当前用作AP的频段信息
get_ap_band() {
  output=$(iwconfig 2>&1 | grep -C 2 Mode:Master)
  contains_aswlan=$(echo "$output" | grep aswlan)
  if [[ ! -z "$contains_aswlan" ]]; then
    contains_aswlan=$(echo "$contains_aswlan" | awk 'NR==1{print $1}')
    output=$(iwconfig 2>&1 | grep -C 2 $contains_aswlan | grep Mode:Master)
    band=$(echo "$output" | awk '{print $2}' | cut -d':' -f2 | tr -d ' ')
    if [[ $(echo "$band > 5" | bc) -eq 1 ]]; then
      echo "5GHz"
    else
      echo "2.4GHz"
    fi
  else
    channel=$(iw dev | grep channel | awk '{print $2}')
    if [[ $(echo "$channel > 14" | bc) -eq 1 ]]; then
      echo "5GHz"
    else
      echo "2.4GHz"
    fi
  fi
  
  return 0
}

# 获取当前用作AP的信道信息
get_ap_channel() {
  local output=$(iw dev | grep -C 1 "type AP")
  local channel=$(echo "$output" | grep -oP 'channel\s+\K[\d]+')
  echo $channel
  return 0
}

# 设置当前AP的信道
set_ap_channel() {
  check_args "$1"
  local current_channel=$(get_ap_channel);
  local current_band=$(get_ap_band);
  local set_channel="$1";
  if [ "$current_channel" == "$set_channel" ]; then
    echo "Set the channel to be consistent with the current one."
    exit 1
  fi

  if [[ "$current_band" == "5GHz" ]]; then
    supported_channels=(36 40 44 48 149 153 157 161 165)
  else
    supported_channels=($(seq 1 11))
  fi

  found=false
  for channel in "${supported_channels[@]}"; do
    if [[ "$channel" == "$set_channel" ]]; then
        found=true
        break
    fi
  done

  if [ "$found" == "false" ]; then
    echo "The channel setting is not in the support list."
    exit 1
  else
    local band=$(echo "$current_band" | grep -oE '5|2\.4')
    local ap_file_path="/usr/local/astrostation/hostap"
    local ap_bin="/usr/local/astrostation/bin/as_ap"
    if [[ "$band" == "5" ]]; then
      sudo sed -i 's/^channel=.*/channel='$set_channel'/' "$ap_file_path/as_5g.conf"
    else
      sudo sed -i 's/^channel=.*/channel='$set_channel'/' "$ap_file_path/as_2.4g.conf"
    fi
    sync
    $ap_bin
  fi
  return 0
}

# 解析命令行参数
case "$1" in
    "scan")
        scan_networks
        ;;
    "set")
        set_wifi "$2" "$3" "$4"
        ;;
    "select")
        select_wifi "$2" "$3"
        ;;
    "disconnect")
        disconnect_wifi
        ;;
    "reconnect")
        reconnect_wifi
        ;;
    "remove")
        remove_wifi "$2"
        ;;
    "status")
        get_status
        ;;
    "list")
        get_list
        ;;
    "type")
        get_ap_type
        ;;
    "set_band")
        set_ap_band "$2"
        ;;
    "get_band")
        get_ap_band
        ;;
    "get_channel")
        get_ap_channel
        ;;
    "set_channel")
        set_ap_channel "$2"
        ;;
    *)
        echo "Commands:"
        echo "    scan"
        echo "    set <SSID> [,<password>] <bssid>"
        echo "    select <SSID> <bssid>"
        echo "    disconnect"
        echo "    reconnect"
        echo "    remove <SSID>"
        echo "    status"
        echo "    list"
        echo "    type"
        echo "    set_band <band>"
        echo "    get_band"
        echo "    get_channel"
        echo "    set_channel <channel>"
        exit 1
        ;;
esac

exit 0
