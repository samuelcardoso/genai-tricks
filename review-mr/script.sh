#!/bin/bash

# Verifica se o número correto de argumentos foi fornecido
if [ "$#" -ne 1 ]; then
    echo "Uso: $0 <PR_ID>"
    exit 1
fi

# Verificar se as dependências estão instaladas
for cmd in jq xclip git; do
    if ! command -v $cmd &> /dev/null; then
        echo "Erro: '$cmd' não está instalado. Por favor, instale-o para continuar."
        exit 1
    fi
done

# Parâmetros recebidos via linha de comando
PR_ID=$1
MAX_SIZE=51200  # Definir limite de tamanho para 50 KB

# Obter o diretório atual do projeto
PROJECT_DIR=$(pwd)

# Variáveis do GitHub
GITHUB_URL="https://api.github.com"

if [ -z "$GITHUB_TOKEN" ]; then
    echo "Erro: O token de acesso do GitHub não está definido. Por favor, exporte 'GITHUB_TOKEN' com seu token."
    exit 1
fi

# Mudar para o diretório do projeto (garantia, caso necessário)
cd $PROJECT_DIR || { echo "Erro: Não foi possível acessar o diretório do projeto"; exit 1; }

# Obter URL do repositório a partir do Git
REPO_URL=$(git config --get remote.origin.url)

# Remover o ".git" do final da URL
REPO_PATH=$(basename -s .git "$REPO_URL")

# Obter nome do usuário e do repositório a partir da URL
USER_REPO=$(echo "$REPO_URL" | sed -E 's/.*[:\/]([^\/]+\/[^\/]+)\.git/\1/')

# Verificar se a string USER_REPO está correta
if [ -z "$USER_REPO" ]; then
    echo "Erro: Não foi possível extrair o nome do repositório do URL $REPO_URL."
    exit 1
fi

# Obter informações do PR via API do GitHub
PR_DETAILS=$(curl --silent --header "Authorization: token $GITHUB_TOKEN" "$GITHUB_URL/repos/$USER_REPO/pulls/$PR_ID")

# Extrair dados importantes
SOURCE_BRANCH=$(echo "$PR_DETAILS" | jq -r '.head.ref')
TARGET_BRANCH=$(echo "$PR_DETAILS" | jq -r '.base.ref')
TITLE=$(echo "$PR_DETAILS" | jq -r '.title')
DESCRIPTION=$(echo "$PR_DETAILS" | jq -r '.body')

# Verificar se o PR foi obtido corretamente
if [ -z "$SOURCE_BRANCH" ] || [ "$SOURCE_BRANCH" == "null" ]; then
    echo "Erro: Não foi possível buscar informações sobre o PR $PR_ID."
    exit 1
fi

echo "Obtendo branches..."

# Fetch da branch de destino
git fetch origin $TARGET_BRANCH

# Verificar se já estamos na branch correta
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "$SOURCE_BRANCH" ]; then
    # Fetch e checkout da branch do PR
    git fetch origin pull/$PR_ID/head:$SOURCE_BRANCH
    git checkout $SOURCE_BRANCH
else
    echo "Já estamos na branch $SOURCE_BRANCH. Atualizando..."
    git fetch origin $SOURCE_BRANCH
    git reset --hard origin/$SOURCE_BRANCH  # Força a branch local a se alinhar com a remota
fi

echo "Gerando diff e preparando o prompt..."

# Garantir que a branch de destino está atualizada
git fetch origin $TARGET_BRANCH

# Comparar as branches (gera o diff com mais contexto)
git diff -U10 origin/$TARGET_BRANCH...$SOURCE_BRANCH > diff_patch.txt

# Obter lista de arquivos modificados
MODIFIED_FILES=$(git diff --name-only origin/$TARGET_BRANCH...$SOURCE_BRANCH)

# Montar mensagem para o ChatGPT e copiar para a área de transferência
{
    echo "## Título do Pull Request: $TITLE"
    echo
    echo "### Descrição:"
    echo "$DESCRIPTION"
    echo
    echo "### Branch de Origem: $SOURCE_BRANCH"
    echo "### Branch de Destino: $TARGET_BRANCH"
    echo
    echo "### Arquivos Modificados:"
    echo "$MODIFIED_FILES"
    echo
    echo "### Instruções para o ChatGPT:"
    echo "Por favor, revise o Pull Request descrito abaixo, focando nos seguintes aspectos:"
    echo "- Qualidade do código e aderência às melhores práticas."
    echo "- Possíveis bugs ou problemas de lógica."
    echo "- Sugestões de melhorias ou otimizações."
    echo "- Verificação de segurança e tratamento de erros."
    echo "Forneça um feedback construtivo e detalhado e apresente as alterações (ponto a ponto) que devem ser realizadas no código, pois vou adicioná-las no comentário do review no GitHub."
    echo
    echo "### Conteúdo Antes das Alterações (branch $TARGET_BRANCH):"
    
    # Para cada arquivo modificado, mostrar o conteúdo antes das alterações
    for FILE in $MODIFIED_FILES; do
        echo "#### Arquivo: $FILE"
        
        # Verifica se o arquivo existe na branch de destino
        if git ls-tree -r origin/$TARGET_BRANCH --name-only | grep -Fxq "$FILE"; then
            # Verificar o tamanho do arquivo
            FILE_SIZE=$(git cat-file -s "origin/$TARGET_BRANCH:$FILE")
            
            if [ "$FILE_SIZE" -le "$MAX_SIZE" ]; then
                echo "\`\`\`"
                git show "origin/$TARGET_BRANCH:$FILE"
                echo "\`\`\`"
            else
                echo "**Arquivo omitido, tamanho ($FILE_SIZE bytes) excede o limite de $MAX_SIZE bytes**"
            fi
        else
            echo "**Arquivo não encontrado na branch $TARGET_BRANCH**"
        fi
        
        echo
    done
    
    echo "### Alterações Detalhadas (diff com contexto):"
    echo "\`\`\`diff"
    cat diff_patch.txt
    echo "\`\`\`"
} | xclip -selection clipboard

# Apagar o arquivo diff_patch.txt
rm diff_patch.txt

echo "O output foi copiado para a área de transferência!"
