#!/bin/bash

# --- ПУТИ К ФАЙЛАМ СКРИПТА ---
# Определяем пути согласно стандарту XDG для лучшей интеграции в систему
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pz-manager"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/pz-manager"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/pz-manager"

# Убедимся, что директории существуют
mkdir -p "$CONFIG_DIR" "$CACHE_DIR" "$LOG_DIR"

# Определяем пути к файлам
CONFIG_FILE="${CONFIG_DIR}/pz_manager.conf"
MOD_CACHE_FILE="${CACHE_DIR}/zomboid_mod_cache.txt"
LOG_FILE="${LOG_DIR}/script_debug.log"

EDITOR=${EDITOR:-nano} # Используем системный редактор, если он задан, иначе nano

log() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# --- ЦВЕТА ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# --- УТИЛИТЫ ---
pause() { read -rp "Нажмите Enter для продолжения..."; }
print_header() { clear; echo -e "\n--- $1 ---\n"; }
contains_element () {
  local e match="$1"; shift
  for e; do [[ "$e" == "$match" ]] && return 0; done
  return 1
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # Если конфиг есть, загружаем его
        echo -e "${GREEN}Конфигурационный файл найден в ${CONFIG_DIR}${NC}"
        echo -e "${GREEN}Загружаю настройки...${NC}"
        source "$CONFIG_FILE"
        sleep 1
    else
        # Если конфига нет, запускаем интерактивную настройку
        print_header "Первый запуск: Настройка"
        echo -e "${YELLOW}Конфигурационный файл не найден.${NC}"
        echo "Давайте создадим его сейчас. Пожалуйста, укажите пути к вашим файлам."
        echo "Вы можете просто нажимать Enter, чтобы использовать значения по умолчанию."

        local default_ini="$HOME/Zomboid/Server/myzomboidworld.ini"
        echo -e -n "Путь к .ini файлу вашего мира [${YELLOW}${default_ini}${NC}]: "
        read ini_path
        INI_FILE=${ini_path:-$default_ini}

        local default_sandbox="$HOME/Zomboid/Server/myzomboidworld_SandboxVars.lua"
        echo -e -n "Путь к SandboxVars.lua файлу [${YELLOW}${default_sandbox}${NC}]: "
        read sandbox_path
        SANDBOX_FILE=${sandbox_path:-$default_sandbox}

        local default_saves="$HOME/Zomboid/Saves/Multiplayer/myzomboidworld"
        echo -e -n "Путь к папке сохранений мира [${YELLOW}${default_saves}${NC}]: "
        read saves_path
        SAVES_DIR=${saves_path:-$default_saves}
        
        local default_service="pzserver.service"
        echo -e -n "Имя службы systemd для сервера [${YELLOW}${default_service}${NC}]: "
        read service_name
        PZ_SERVICE_NAME=${service_name:-$default_service}

        # Создаем и записываем конфиг
        echo "Создаю файл: $CONFIG_FILE"
        {
            echo "# --- Конфигурация для менеджера сервера Project Zomboid ---"
            echo ""
            echo "# Полный путь к основному .ini файлу вашего мира"
            echo "INI_FILE=\"$INI_FILE\""
            echo ""
            echo "# Полный путь к файлу с настройками песочницы"
            echo "SANDBOX_FILE=\"$SANDBOX_FILE\""
            echo ""
            echo "# Полный путь к папке с файлами сохранений этого мира"
            echo "SAVES_DIR=\"$SAVES_DIR\""
            echo ""
            echo "# Имя службы systemd, которая управляет сервером"
            echo "PZ_SERVICE_NAME=\"$PZ_SERVICE_NAME\""
        } > "$CONFIG_FILE"
        
        echo -e "\n${GREEN}Конфигурационный файл успешно создан!${NC}"
        echo "Вы всегда можете отредактировать его вручную: ${CONFIG_FILE}"
        pause
    fi
}

# --- ПРОВЕРКИ ПРИ ЗАПУСКЕ ---
check_dependencies() {
    local missing_deps=()
    for cmd in curl grep sed awk paste tr systemctl journalctl "$EDITOR"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${RED}Ошибка: Для работы скрипта не найдены следующие утилиты:${NC}"
        printf " - %s\n" "${missing_deps[@]}"
        exit 1
    fi
}

check_files() {
    if [[ ! -f "$INI_FILE" ]]; then
        echo -e "${RED}Критическая ошибка: Не найден файл конфигурации .ini:${NC}\n$INI_FILE"
        echo -e "${YELLOW}Убедитесь, что путь в файле pz_manager.conf указан верно.${NC}"
        exit 1
    fi
    if [[ ! -f "$SANDBOX_FILE" ]]; then
        echo -e "${RED}Критическая ошибка: Не найден файл конфигурации Sandbox.lua:${NC}\n$SANDBOX_FILE"
        echo -e "${YELLOW}Убедитесь, что путь в файле pz_manager.conf указан верно.${NC}"
        exit 1
    fi
}

# --- ФУНКЦИИ УПРАВЛЕНИЯ МОДАМИ ---

fetch_mod_info_from_steam() {
    local workshop_id=$1
    log "\n---[ Обработка Workshop ID: ${workshop_id} ]---"
    local url="https://steamcommunity.com/sharedfiles/filedetails/?id=${workshop_id}"
    local page_content
    
    page_content=$(curl -sL --connect-timeout 15 \
        -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.4896.88 Safari/537.36" \
        --cookie "birthtime=568022401; lastagecheckage=1-January-1988" \
        "$url")
    
    if [[ -z "$page_content" ]] || echo "$page_content" | grep -q "agegate_prompt"; then
        log "!!! ОШИБКА: Не удалось загрузить страницу или сработал Age Gate для ${workshop_id}"
        echo "Ошибка: Не удалось загрузить страницу мода ${workshop_id}" >&2
        return 1
    fi

    local mod_name
    mod_name=$(echo "$page_content" | grep -oP '(?<=<title>Steam Workshop::).*?(?=</title>)' | sed -e 's/&/\&/g' -e 's/"/"/g' | sed -e 's/[:"'''']//g' -e 's/^[ \t]*//;s/[ \t]*$//')
    log "Найдено имя: '${mod_name}'"

    local clean_text_content
    clean_text_content=$(echo "$page_content" | sed -e 's|<br */\?>|\n|gi' -e 's/<[^>]*>//g' -e 's/ / /g' -e 's/&/\&/g')

    local mod_ids
    mod_ids=$(echo "$clean_text_content" \
        | grep -i -E "mod id|modid" \
        | sed -E 's/.*://' \
        | sed 's/,/;/g' \
        | sed 's/[[:space:]]//g' \
        | paste -sd';' - \
        | sed -E 's/(;){2,}/;/g' \
        | sed -E 's/^;|;$//g'
    )
    log "Найдены Mod ID: '${mod_ids}'"

    local map_folder
    map_folder=$(echo "$clean_text_content" \
        | grep -i "Map Folder" \
        | sed -E 's/.*Map Folder:[[:space:]]*//I' \
        | head -n 1 \
        | xargs
    )
    log "Найдена папка карты: '${map_folder}'"

    [[ -z "$mod_name" ]] && mod_name="(Имя не найдено)"
    [[ -z "$mod_ids" ]] && mod_ids="(Mod ID не найден)"
    [[ -z "$map_folder" ]] && map_folder="(Папка карты не найдена)"

    local final_cache_line="${workshop_id}:${mod_ids}:${map_folder}:${mod_name}"
    log "Итоговая строка для кэша: ${final_cache_line}"
    echo "$final_cache_line"
}

update_mod_cache() {
    local workshop_id=$1
    sed -i "/^${workshop_id}:/d" "$MOD_CACHE_FILE"
    local mod_info
    mod_info=$(fetch_mod_info_from_steam "$workshop_id")
    if [[ $? -eq 0 && -n "$mod_info" ]]; then
        echo "$mod_info" >> "$MOD_CACHE_FILE"
    fi
}

get_name_by_workshop_id() {
    local workshop_id=$1
    local cached_entry
    cached_entry=$(grep "^${workshop_id}:" "$MOD_CACHE_FILE" | head -n 1)
    if [[ -n "$cached_entry" ]]; then
        echo "$cached_entry" | cut -d':' -f4
    else
        update_mod_cache "$workshop_id"
        cached_entry=$(grep "^${workshop_id}:" "$MOD_CACHE_FILE" | head -n 1)
        if [[ -n "$cached_entry" ]]; then echo "$cached_entry" | cut -d':' -f4; else echo "(Имя не найдено)"; fi
    fi
}

get_name_by_mod_id() {
    local mod_id_to_find="$1"
    log "Ищем имя для Mod ID '${mod_id_to_find}' в кэше..."
    local search_result_line
    search_result_line=$(grep -E ":([^:]*;)?${mod_id_to_find}(;[^:]*)?:" "$MOD_CACHE_FILE" | head -n 1)

    if [[ -n "$search_result_line" ]]; then
        local found_name
        found_name=$(echo "$search_result_line" | cut -d':' -f4)
        log "Найдена строка: '${search_result_line}'. Извлечено имя: '${found_name}'."
        echo "$found_name"
    else
        log "!!! Имя для '${mod_id_to_find}' НЕ НАЙДЕНО в кэше."
        echo "(Имя не привязано к Workshop ID)"
    fi
}

add_item_to_list() {
    local line_name=$1; local item_to_add=$2; local file=$3
    local current_line
    current_line=$(grep "^${line_name}=" "$file")
    local current_value
    current_value=$(echo "$current_line" | cut -d'=' -f2)
    if [[ ";$current_value;" == *";$item_to_add;"* ]]; then
        echo -e "${YELLOW}Предупреждение: Элемент '$item_to_add' уже есть в списке '$line_name'. Пропуск.${NC}"
        return 1
    fi
    local new_value
    if [[ -z "$current_value" ]]; then new_value="$item_to_add"; else new_value="$current_value;$item_to_add"; fi
    sed -i "s|^${line_name}=.*|${line_name}=${new_value}|" "$file"
    echo -e "${GREEN}Элемент '$item_to_add' добавлен в '$line_name'.${NC}"
    return 0
}

list_mods() {
    local line_name=$1; local title=$2; print_header "$title"
    local current_value
    current_value=$(grep "^${line_name}=" "$INI_FILE" | cut -d'=' -f2)
    if [[ -z "$current_value" ]]; then echo "Список пуст."; pause; return; fi
    IFS=';' read -ra id_array <<< "$current_value"
    for i in "${!id_array[@]}"; do
        local mod_id="${id_array[i]}"; local mod_name=""
        if [[ "$line_name" == "WorkshopItems" ]]; then
            mod_name=$(get_name_by_workshop_id "$mod_id")
        else
            mod_name=$(get_name_by_mod_id "$mod_id")
        fi
        echo -e "$((i+1))) ${YELLOW}${mod_id}${NC} - $mod_name"
    done
    echo ""; pause
}

remove_id_menu() {
    local line_name=$1; local title=$2; print_header "$title"
    local current_value
    current_value=$(grep "^${line_name}=" "$INI_FILE" | cut -d'=' -f2)
    IFS=';' read -ra id_array <<< "$current_value"
    if [ ${#id_array[@]} -eq 0 ]; then echo "Список пуст."; pause; return; fi
    echo "Выберите номера для удаления (можно несколько, через пробел):"
    for i in "${!id_array[@]}"; do
        local mod_id="${id_array[i]}"; local mod_name=""
        if [[ "$line_name" == "WorkshopItems" ]]; then
            mod_name=$(get_name_by_workshop_id "$mod_id")
        else
            mod_name=$(get_name_by_mod_id "$mod_id")
        fi
        echo -e "$((i+1))) ${YELLOW}${mod_id}${NC} - $mod_name"
    done
    echo "0) Отмена"
    read -rp "Ваш выбор: " -a choices
    if [[ " ${choices[*]} " =~ " 0 " || ${#choices[@]} -eq 0 ]]; then echo "Отмена."; pause; return; fi
    local indices_to_remove=(); local valid_choice=true
    for choice in "${choices[@]}"; do
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le ${#id_array[@]} ]; then
            indices_to_remove+=($((choice-1)))
        else
            echo -e "${RED}Неверный выбор: $choice${NC}"; valid_choice=false
        fi
    done
    if ! $valid_choice; then pause; return; fi
    local new_id_array=(); local removed_ids_str=""
    for i in "${!id_array[@]}"; do
        if contains_element "$i" "${indices_to_remove[@]}"; then
            removed_ids_str+="${id_array[i]} "
        else
            new_id_array+=("${id_array[i]}")
        fi
    done
    echo "Удаляются ID: $removed_ids_str"
    local new_string
    new_string=$(IFS=';'; echo "${new_id_array[*]}")
    sed -i "s|^${line_name}=.*|${line_name}=${new_string}|" "$INI_FILE"
    echo -e "${GREEN}Готово!${NC}"; pause
}

add_mod_from_url() {
    print_header "Добавление мода по URL"
    read -rp "Вставьте URL мода из Steam Workshop: " url
    if [[ -z "$url" ]]; then echo -e "${RED}URL не может быть пустым.${NC}"; pause; return; fi
    local workshop_id
    workshop_id=$(echo "$url" | grep -oP '(?<=id=)[0-9]+')
    if [[ -z "$workshop_id" ]]; then echo -e "${RED}Не удалось извлечь Workshop ID из URL.${NC}"; pause; return; fi
    echo "Извлечен Workshop ID: ${workshop_id}. Получаю информацию о моде..."
    local mod_info
    mod_info=$(fetch_mod_info_from_steam "$workshop_id")
    if [[ $? -ne 0 || -z "$mod_info" ]]; then echo -e "${RED}Не удалось получить информацию.${NC}"; pause; return; fi

    local parsed_ws_id parsed_mod_ids_str parsed_map_folder parsed_mod_name
    parsed_ws_id=$(echo "$mod_info" | cut -d':' -f1)
    parsed_mod_ids_str=$(echo "$mod_info" | cut -d':' -f2)
    parsed_map_folder=$(echo "$mod_info" | cut -d':' -f3)
    parsed_mod_name=$(echo "$mod_info" | cut -d':' -f4)

    echo "Найден мод: ${parsed_mod_name}"
    add_item_to_list "WorkshopItems" "$parsed_ws_id" "$INI_FILE"
    update_mod_cache "$parsed_ws_id"

    if [[ "$parsed_mod_ids_str" == "(Mod ID не найден)" ]]; then
        echo -e "${YELLOW}На странице не найден Mod ID. Workshop ID добавлен, но Mod ID нужно ввести вручную, если он требуется.${NC}"
    else
        IFS=';' read -ra mod_id_array <<< "$parsed_mod_ids_str"
        if [ ${#mod_id_array[@]} -eq 1 ]; then
            echo "Найден один Mod ID: ${mod_id_array[0]}"
            add_item_to_list "Mods" "${mod_id_array[0]}" "$INI_FILE"
        else
            local selected_indices=()
            while true; do
                print_header "Найдено несколько Mod ID. Выберите нужные:"; echo "Мод: ${parsed_mod_name}"
                for i in "${!mod_id_array[@]}"; do
                    local checkbox="[ ]"
                    if contains_element "$i" "${selected_indices[@]}"; then checkbox="[${GREEN}x${NC}]"; fi
                    echo -e "$((i+1))) $checkbox ${mod_id_array[i]}"
                done
                echo -e "-------------------------------------------------\nВведите номер, чтобы отметить/снять отметку.\nВведите '${GREEN}d${NC}' (done), чтобы закончить и добавить выбранные.\nВведите '${RED}c${NC}' (cancel), чтобы отменить добавление Mod ID."
                read -rp "Ваш выбор: " choice
                if [[ "$choice" == "d" ]]; then break; fi; if [[ "$choice" == "c" ]]; then selected_indices=(); break; fi
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le ${#mod_id_array[@]} ]; then
                    local index=$((choice-1))
                    if contains_element "$index" "${selected_indices[@]}"; then
                        local new_selected=(); for i in "${selected_indices[@]}"; do [[ "$i" != "$index" ]] && new_selected+=("$i"); done; selected_indices=("${new_selected[@]}")
                    else
                        selected_indices+=("$index")
                    fi
                else
                    echo -e "${RED}Неверный ввод.${NC}"; sleep 1
                fi
            done
            if [ ${#selected_indices[@]} -gt 0 ]; then
                for index in "${selected_indices[@]}"; do add_item_to_list "Mods" "${mod_id_array[index]}" "$INI_FILE"; done
            else
                echo "Не выбрано ни одного Mod ID. Добавление отменено."
            fi
        fi
    fi

    if [[ "$parsed_map_folder" != "(Папка карты не найдена)" ]]; then
        echo -e "\n${CYAN}Найдена папка карты: ${YELLOW}${parsed_map_folder}${NC}"
        read -rp "Добавить ее в параметр 'Map' в ${INI_FILE##*/}? (y/n): " confirm_map
        if [[ "$confirm_map" == "y" ]]; then
            add_item_to_list "Map" "$parsed_map_folder" "$INI_FILE"
        else
            echo "Добавление папки карты пропущено."
        fi
    fi

    pause
}

update_all_mods_cache() {
    print_header "Обновление кэша имен модов"
    log "\n---[ Запуск функции update_all_mods_cache ]---"
    echo "Это может занять некоторое время."
    read -rp "Начать обновление? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then
        log "Пользователь отменил обновление."
        echo "Отмена."; pause; return;
    fi

    local workshop_ids_line
    workshop_ids_line=$(grep "^WorkshopItems=" "$INI_FILE" | cut -d'=' -f2)
    log "Прочитана строка WorkshopItems из .ini: '${workshop_ids_line}'"

    if [[ -z "$workshop_ids_line" ]]; then
        log "!!! Строка WorkshopItems пуста. Обновление прервано."
        echo "Список WorkshopItems пуст."; pause; return;
    fi

    local TEMP_CACHE_FILE
    TEMP_CACHE_FILE=$(mktemp)
    log "Создан временный файл кэша: ${TEMP_CACHE_FILE}"

    IFS=';' read -ra id_array <<< "$workshop_ids_line"
    local total=${#id_array[@]}; local current=0
    log "Начинаю перебор ${total} Workshop ID."

    for id in "${id_array[@]}"; do
        current=$((current+1))
        if [[ -z "$id" ]]; then
            log "!!! Обнаружен пустой ID в списке, пропуск."
            continue
        fi
        log "--- Итерация ${current}/${total}. Вызываю fetch_mod_info_from_steam для ID: ${id} ---"
        echo -ne "Обновление... (${current}/${total}) - ${id} \033[0K\r"
        local mod_info
        
        mod_info=$(fetch_mod_info_from_steam "$id")
        
        log "Результат от fetch_mod_info_from_steam: '${mod_info}'"

        if [[ $? -eq 0 && -n "$mod_info" ]]; then
            log "Записываю строку в временный кэш."
            echo "$mod_info" >> "$TEMP_CACHE_FILE"
        else
            log "!!! Результат пуст или была ошибка. Пропускаю запись в кэш для ID ${id}."
        fi
    done

    log "Перебор завершен. Перемещаю ${TEMP_CACHE_FILE} в ${MOD_CACHE_FILE}"
    mv "$TEMP_CACHE_FILE" "$MOD_CACHE_FILE"
    echo -e "\n${GREEN}Кэш имен модов успешно обновлен!${NC}"; pause
}

search_mod_id_menu() {
    print_header "Поиск ID мода"
    read -rp "Введите Workshop ID или Mod ID для поиска: " search_id
    if [[ -z "$search_id" ]]; then
        echo -e "${RED}Поисковый запрос не может быть пустым.${NC}"; pause; return
    fi

    local found=false

    local workshop_list
    workshop_list=$(grep "^WorkshopItems=" "$INI_FILE" | cut -d'=' -f2)
    if [[ ";$workshop_list;" == *";$search_id;"* ]]; then
        found=true
        echo -e "\n${GREEN}Найден в списке WorkshopItems!${NC}"
        local mod_name
        mod_name=$(get_name_by_workshop_id "$search_id")
        echo -e "ID: ${YELLOW}${search_id}${NC} - $mod_name"
    fi

    local mods_list
    mods_list=$(grep "^Mods=" "$INI_FILE" | cut -d'=' -f2)
    if [[ ";$mods_list;" == *";$search_id;"* ]]; then
        found=true
        echo -e "\n${GREEN}Найден в списке Mod ID!${NC}"
        local mod_name
        mod_name=$(get_name_by_mod_id "$search_id")
        echo -e "ID: ${YELLOW}${search_id}${NC} - $mod_name"
    fi

    if ! $found; then
        echo -e "\n${YELLOW}ID '${search_id}' не найден ни в одном из списков.${NC}"
    fi

    pause
}

mods_menu() {
    touch "$MOD_CACHE_FILE"
    while true; do
        print_header "Управление модами"
        echo -e "--- ${CYAN}Просмотр${NC} ---\n1. Показать Workshop ID (с именами)\n2. Показать Mod ID (с именами)\n"
        echo -e "--- ${CYAN}Добавление${NC} ---\n3. Добавить мод по URL (рекомендуется)\n4. Добавить Workshop ID вручную\n5. Добавить Mod ID(ы) вручную\n"
        echo -e "--- ${RED}Удаление${NC} ---\n6. Удалить Workshop ID (несколько за раз)\n7. Удалить Mod ID (несколько за раз)\n"
        echo -e "--- ${YELLOW}Инструменты${NC} ---\n8. Поиск мода по ID\n9. Обновить кэш имен всех модов\n--------------------------\n0. Назад в главное меню\n"
        read -rp "Выберите действие: " choice
        case $choice in
            1) list_mods "WorkshopItems" "Список Workshop ID" ;;
            2) list_mods "Mods" "Список Mod ID" ;;
            3) add_mod_from_url ;;
            4) read -rp "Введите Workshop ID: " id; if [[ -n "$id" ]]; then add_item_to_list "WorkshopItems" "$id" "$INI_FILE" && update_mod_cache "$id"; else echo -e "${RED}Пусто!${NC}"; fi; pause ;;
            5) read -rp "Введите Mod ID(ы) (через ';'): " id; if [[ -n "$id" ]]; then IFS=';' read -ra ids <<< "$id"; for single_id in "${ids[@]}"; do add_item_to_list "Mods" "$single_id" "$INI_FILE"; done; else echo -e "${RED}Пусто!${NC}"; fi; pause ;;
            6) remove_id_menu "WorkshopItems" "Удаление Workshop ID" ;;
            7) remove_id_menu "Mods" "Удаление Mod ID" ;;
            8) search_mod_id_menu ;;
            9) update_all_mods_cache ;;
            0) break ;;
            *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
        esac
    done
}

wipe_world() {
    print_header "ВАЙП СЕРВЕРА"; echo -e "${YELLOW}Останавливаю сервер...${NC}"; sudo systemctl stop "${PZ_SERVICE_NAME}"
    echo ""; echo -e "${RED}ВНИМАНИЕ! Это действие безвозвратно удалит весь прогресс мира.${NC}"
    read -rp "Для подтверждения удаления введите 'wipe': " confirm
    if [ "$confirm" == "wipe" ]; then
        echo "Удаляю папку мира..."; rm -rf "$SAVES_DIR"; echo -e "${GREEN}Мир удален.${NC}"
        echo ""; echo -e "${YELLOW}Запускаю сервер с новым миром...${NC}"; sudo systemctl start "${PZ_SERVICE_NAME}"; echo -e "${GREEN}Сервер запущен.${NC}"
    else
        echo "Отмена. Запускаю сервер обратно..."; sudo systemctl start "${PZ_SERVICE_NAME}"; echo -e "${GREEN}Сервер запущен без изменений.${NC}"
    fi
    pause
}

show_info_menu() {
    print_header "Справка и информация"
    
    echo -e "${CYAN}--- Файлы конфигурации мира ---${NC}"
    echo -e "Скрипт работает со следующими файлами, указанными в вашем конфиге:"
    echo -e "INI-файл:      ${YELLOW}$INI_FILE${NC}"
    echo -e "Sandbox-файл:  ${YELLOW}$SANDBOX_FILE${NC}"
    echo -e "Папка с миром:  ${YELLOW}$SAVES_DIR${NC}"
    echo -e "Имя службы:     ${YELLOW}${PZ_SERVICE_NAME}${NC}"
    echo ""
    
    echo -e "${CYAN}--- Файлы самого скрипта ---${NC}"
    echo -e "Основной конфиг: ${YELLOW}${CONFIG_FILE}${NC}"
    echo -e "Кеш имен модов:   ${YELLOW}${MOD_CACHE_FILE}${NC}"
    echo -e "Лог-файл скрипта: ${YELLOW}${LOG_FILE}${NC}"
    echo ""

    echo -e "${CYAN}--- Полезно знать ---${NC}"
    echo -e " • ${YELLOW}Первый запуск:${NC} При первом запуске скрипт создает конфигурационный файл."
    echo -e "   Если вы переместили скрипт или хотите сбросить настройки, просто удалите этот файл."
    echo -e " • ${YELLOW}Обновление кеша:${NC} Если вы вручную изменили список Workshop ID, не забудьте"
    echo -e "   запустить 'Обновить кэш имен всех модов' в меню модов."
    echo -e " • ${YELLOW}GitHub:${NC} Актуальная версия скрипта и документация всегда доступны"
    echo -e "   на нашей странице на GitHub. https://github.com/ArthurPierce23/Project-Zomboid-Dedicated-Tool"
    echo ""

    pause
}

# --- ОСНОВНОЙ ЦИКЛ СКРИПТА ---
check_dependencies
load_config
check_files

while true; do
    clear
    # Проверяем статус через переменную, чтобы не вызывать systemctl лишний раз
    if systemctl is-active --quiet "${PZ_SERVICE_NAME}"; then
        status_text="active"
        status_color=$GREEN
    else
        status_text="inactive"
        status_color=$RED
    fi

    echo -e "\n${CYAN}==== Пульт управления сервером Project Zomboid ====${NC}"
    echo -e "Статус: ${status_color}${status_text}${NC}"
    echo "--------------------------------------------------"
    echo -e "           --- ${CYAN}Редактирование${NC} ---"
    echo -e "1. Редактировать .ini конфиг (${YELLOW}${INI_FILE##*/}${NC})"
    echo -e "2. Редактировать Sandbox.lua (${YELLOW}${SANDBOX_FILE##*/}${NC})"
    echo -e "3. Управление модами"
    echo ""
    echo -e "          --- ${CYAN}Управление сервером${NC} ---"
    echo -e "4. Старт сервера"
    echo -e "5. Стоп сервера"
    echo -e "6. Рестарт сервера"
    echo -e "7. Статус (детально)"
    echo -e "8. Логи в реальном времени"
    echo ""
    echo -e "             --- ${YELLOW}Опасная зона${NC} ---"
    echo -e "9. ВАЙП сервера (с подтверждением)"
    echo "--------------------------------------------------"
    echo -e "0. Справка и информация"
    echo -e "q. Выход\n"
    read -rp "Выберите действие: " choice
    case $choice in
        1) "$EDITOR" "$INI_FILE" ;;
        2) "$EDITOR" "$SANDBOX_FILE" ;;
        3) mods_menu ;;
        4) echo -e "${YELLOW}Запускаю сервер...${NC}"; sudo systemctl start "${PZ_SERVICE_NAME}"; pause ;;
        5) echo -e "${YELLOW}Останавливаю сервер...${NC}"; sudo systemctl stop "${PZ_SERVICE_NAME}"; pause ;;
        6) echo -e "${YELLOW}Перезапускаю сервер...${NC}"; sudo systemctl restart "${PZ_SERVICE_NAME}"; pause ;;
        7) clear; sudo systemctl status "${PZ_SERVICE_NAME}"; pause ;;
        8) clear; echo "--- Логи сервера (Нажмите Ctrl+C для выхода) ---"; sudo journalctl -u "${PZ_SERVICE_NAME}" -f; echo "Вы вышли из просмотра логов."; pause ;;
        9) wipe_world ;;
        0) show_info_menu ;;
        q|Q) clear; echo "Выход."; exit 0 ;;
        *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
    esac
done
