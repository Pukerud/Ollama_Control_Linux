#!/bin/bash

while true; do
    clear
    echo "======================================================="
    echo "   OLLAMA CONTROL PANEL (Server: $(hostname))"
    echo "======================================================="
    printf "   %-4s %-40s %s\n" "NO" "MODEL NAME" "SIZE"
    echo "   ---------------------------------------------------"

    # 1. Get name and size (Format: Name|Size)
    # We merge columns 3 and 4 (e.g. "2.6" and "GB") to handle spaces
    raw_data=($(ollama list | awk 'NR>1 {print $1 "|" $3 $4}'))

    if [ ${#raw_data[@]} -eq 0 ]; then
        echo "   (No models found)"
    else
        for i in "${!raw_data[@]}"; do
            # Split the line based on "|" character
            IFS="|" read -r m_name m_size <<< "${raw_data[$i]}"
            
            # Print nicely formatted table
            printf "   %2d)  %-40s [%s]\n" "$((i+1))" "$m_name" "$m_size"
        done
    fi
    
    echo "======================================================="
    echo " [1] Download new model (Pull)"
    echo " [2] Change Context on existing (Create)"
    echo " [3] Delete a model (Remove)"
    echo " [4] Exit"
    echo "-------------------------------------------------------"
    read -p " Choose action (1-4): " action

    # Function to get model name from number
    get_model_name() {
        local idx=$(( $1 - 1 ))
        local entry=${raw_data[$idx]}
        # Get only the name (before | character)
        echo "${entry%%|*}"
    }

    case $action in
        1)
            # --- DOWNLOAD ---
            echo ""
            echo "Tip: Check the library at ollama.com"
            read -p "Enter name of model to download (e.g. deepseek-r1): " new_model
            if [ -n "$new_model" ]; then
                echo "Starting download of $new_model..."
                ollama pull "$new_model"
                echo "Done!"
            else
                echo "Cancelled."
            fi
            ;;

        2)
            # --- CHANGE CONTEXT ---
            echo ""
            read -p "Choose number of the model you want to modify: " n
            target=$(get_model_name "$n")

            if [ -z "$target" ] || [ "$target" == "" ]; then
                echo "Invalid selection."
            else
                echo "Selected model: $target"
                read -p "How much context do you want? (e.g. 32000): " ctx
                if [ -n "$ctx" ]; then
                    suffix=$(echo $ctx | tr -d ' ')
                    new_name="${target}-${suffix}"
                    
                    echo "FROM $target" > Modelfile.temp
                    echo "PARAMETER num_ctx $ctx" >> Modelfile.temp
                    
                    echo "Creating $new_name (This may take a while)..."
                    ollama create "$new_name" -f Modelfile.temp
                    rm Modelfile.temp
                    
                    echo "Success! New model created: $new_name"
                else
                    echo "Missing context value."
                fi
            fi
            ;;

        3)
            # --- DELETE ---
            echo ""
            read -p "Which number do you want to DELETE? " n
            target=$(get_model_name "$n")
            
            if [ -z "$target" ] || [ "$target" == "" ]; then
                echo "Invalid selection."
            else
                read -p "Are you SURE you want to delete $target? (y/n): " confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    echo "Deleting $target..."
                    ollama rm "$target"
                    echo "Model has been deleted."
                else
                    echo "Deletion cancelled."
                fi
            fi
            ;;

        4)
            # --- EXIT ---
            echo "Have a nice day!"
            exit 0
            ;;

        *)
            echo "Invalid selection, try again."
            ;;
    esac

    echo ""
    read -p "Press Enter to return to the menu..."
done
