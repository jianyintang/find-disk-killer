<div align="center">
  <img src="docs/assets/find-disk-killer-icon.png" width="128" height="128" alt="Ícone do app FindDiskKiller">
  <h1>FindDiskKiller</h1>
  <p><strong>Veja o que continua usando seu disco.</strong></p>
  <p>Comece pela E/S de disco dos apps e siga as evidências pela atividade de arquivos, espaço de agentes de IA e discos físicos.</p>
  <p>
    <a href="README.md">English</a> ·
    <a href="README.zh-CN.md">简体中文</a> ·
    <a href="README.zh-TW.md">繁體中文</a> ·
    <a href="README.ja.md">日本語</a> ·
    <a href="README.ko.md">한국어</a> ·
    <a href="README.de.md">Deutsch</a> ·
    <a href="README.fr.md">Français</a> ·
    <a href="README.es.md">Español</a> ·
    <a href="README.pt-BR.md">Português (Brasil)</a> ·
    <a href="README.ru.md">Русский</a>
  </p>
  <p><strong>macOS 14+ · Apple silicon e Intel · Processamento 100% local</strong></p>
  <p>
    <a href="https://finddiskkiller.com/pt-br/download/"><strong>Baixar para macOS</strong></a> ·
    <a href="https://finddiskkiller.com/pt-br/">Site oficial</a> ·
    <a href="https://finddiskkiller.com/pt-br/how-it-works/">Como funciona</a> ·
    <a href="PRIVACY.md">Privacidade</a> · <a href="SUPPORT.md">Suporte</a>
  </p>
</div>

---

<a href="docs/assets/screenshots/overview-sustained-activity.webp">
  <img src="docs/assets/screenshots/overview-sustained-activity.webp" width="100%" alt="Área Agora completa do FindDiskKiller com atividade contínua do disco, tendências e principais apps.">
</a>

<p align="center"><sub>Encontre atividade contínua do disco e identifique os apps responsáveis. Clique para abrir a imagem original.</sub></p>

FindDiskKiller é uma ferramenta nativa para macOS focada em uma tarefa: seguir a atividade contínua do disco até os apps, arquivos e dispositivos físicos por trás dela. Evidências de CPU, disco e rede ficam organizadas por app, sem reconstruir o contexto entre várias ferramentas do sistema.

<p align="center"><strong>100%</strong> local　·　<strong>0</strong> dados enviados　·　<strong>10</strong> idiomas　·　<strong>macOS 14+</strong></p>

## Todas as informações em um só espaço

### Espaço de agentes de IA

Codex e Claude acumulam conversas, sessões de subagentes, snapshots, visualizações e bancos compartilhados. AI Storage inicia a análise local somente após uma ação explícita, atribui espaço a cada thread ou session e permite revisão completa antes da exclusão permanente.

<a href="docs/assets/screenshots/ai-storage-overview.webp"><img src="docs/assets/screenshots/ai-storage-overview.webp" width="100%" alt="Visão geral do AI Storage com espaço de chats, global e não atribuído para Codex e Claude."></a>

<p align="center"><sub>Meça primeiro o espaço total do provedor e depois separe chats, dados globais e espaço não atribuído.</sub></p>

<p align="center">
  <a href="docs/assets/screenshots/ai-storage-thread-details.webp"><img src="docs/assets/screenshots/ai-storage-thread-details.webp" width="57%" alt="AI Storage do Codex com atividade, subagentes e composição completa do thread selecionado."></a>
  <a href="docs/assets/screenshots/ai-storage-batch-cleanup.webp"><img src="docs/assets/screenshots/ai-storage-batch-cleanup.webp" width="41%" alt="Limpeza em lote com o escopo escolhido e recuperação imediata estimada antes da exclusão permanente."></a>
</p>

<p align="center"><sub>Esquerda: atribuir espaço a uma conversa　·　Direita: revisar idade, projeto e conversas antes de excluir</sub></p>

A análise nunca começa automaticamente. Sessões ativas ou com identidade alterada são ignoradas; provedores incompatíveis nunca levam a gravações diretas no banco nem exclusão manual de transcripts. Sessões do Claude Desktop e Cowork são excluídas atualmente dentro do Claude Desktop.

### Atividade de apps e evidências de arquivos

Compare tendências de CPU, disco e rede de um app e avance para locais abertos e diretórios alterados recentemente. Quando precisar de mais evidências, inicie explicitamente um rastreamento temporário de arquivo ou pasta.

<p align="center">
  <a href="docs/assets/screenshots/app-codex-overview.webp"><img src="docs/assets/screenshots/app-codex-overview.webp" width="49%" alt="Detalhes do Codex com linhas do tempo separadas de CPU, E/S de disco e rede."></a>
  <a href="docs/assets/screenshots/app-codex-file-activity.webp"><img src="docs/assets/screenshots/app-codex-file-activity.webp" width="49%" alt="Atividade de arquivos do Codex com locais relacionados, pastas graváveis e mudanças recentes."></a>
</p>

<p align="center"><sub>Esquerda: verificar se a atividade persiste　·　Direita: entrar nos locais envolvidos</sub></p>

<p align="center"><a href="docs/assets/screenshots/folder-access-trace.webp"><img src="docs/assets/screenshots/folder-access-trace.webp" width="86%" alt="Rastreamento temporário de pasta com taxas solicitadas de leitura e gravação, arquivos ativos e processos."></a></p>

<p align="center"><sub>O rastreamento só funciona após início explícito e mostra E/S solicitada, arquivos ativos e sessões de processo verificadas.</sub></p>

### Discos físicos e integridade

Relacione nomes conhecidos como Macintosh HD ou discos externos à vazão do dispositivo físico e consulte os campos SMART/NVMe que o macOS e o hardware realmente oferecem.

<p align="center">
  <a href="docs/assets/screenshots/disk-live-activity.webp"><img src="docs/assets/screenshots/disk-live-activity.webp" width="49%" alt="Área Discos com vazão de dispositivos físicos, volumes montados e diagnósticos de hardware."></a>
  <a href="docs/assets/screenshots/disk-health.webp"><img src="docs/assets/screenshots/disk-health.webp" width="49%" alt="Integridade do disco com SMART, desgaste, temperatura, gravações do host, histórico de energia e erros."></a>
</p>

<p align="center"><sub>Esquerda: identificar o dispositivo ativo　·　Direita: consultar os dados de integridade fornecidos</sub></p>

## Sem falsa precisão

FindDiskKiller reúne evidências relacionadas sem forçar medições de significados diferentes em um único número:

- **A E/S de apps** representa solicitações de processos em todo o armazenamento, não tráfego NAND físico.
- **A vazão do dispositivo** não pode ser atribuída exatamente a um processo; totais de apps e dispositivos não precisam coincidir.
- **Um local alterado recentemente** indica mudança observada pelo macOS, mas não identifica sozinho quem gravou.
- **A atribuição de banco de IA** é uma estimativa lógica indicada, não espaço físico recuperável imediatamente.

Evidências ausentes, parciais ou incompatíveis aparecem como indisponíveis em vez de serem substituídas por zero.

## Privacidade e permissões

Todo monitoramento, análise e exibição acontecem no Mac. A versão atual não envia nomes de processos, caminhos, números de série ou histórico e não contém anúncios, telemetria, análise nem SDKs de rastreamento de terceiros.

O monitoramento básico de CPU, disco, rede, volumes e processos não exige aprovação de administrador. Somente ao iniciar explicitamente um rastreamento o macOS pode pedir aprovação do componente em segundo plano assinado e de finalidade limitada; locais protegidos também podem exigir Acesso Total ao Disco. Você sempre controla início e fim.

Leia a [Política de Privacidade](PRIVACY.md) · [Política de Segurança](SECURITY.md).

## Instalação

1. Baixe o DMG mais recente, assinado e notarizado, no [site oficial](https://finddiskkiller.com/pt-br/download/).
2. Abra-o e arraste o FindDiskKiller para Aplicativos.
3. Inicie o FindDiskKiller em Aplicativos.

Versões oficiais são compatíveis com Macs Apple silicon e Intel e incluem checksum SHA-256. Não contorne o Gatekeeper se a assinatura ou notarização falhar.

## Desenvolvimento e documentação

<details>
<summary><strong>Compilar do código-fonte e executar testes</strong></summary>

O desenvolvimento requer Xcode 16+ e XcodeGen 2.42.0+.

```bash
git clone https://github.com/jianyintang/find-disk-killer.git
cd find-disk-killer
xcodegen generate
xcodebuild \
  -project FindDiskKiller.xcodeproj \
  -scheme FindDiskKillerApp \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=NO \
  build
make test
```

A compilação sem assinatura cobre o monitoramento básico, mas não o rastreamento privilegiado que exige identidades oficiais do app e helper.

</details>

- [Plano de produto e técnico](docs/find-disk-killer-product-and-technical-plan.md)
- [Plano de rastreamento profundo e integridade do SSD](docs/find-disk-killer-deep-tracing-and-ssd-health-plan.md)
- [Checklist de lançamento no site](docs/website-release-checklist.md)
- [Contribuir](CONTRIBUTING.md)
- [Avisos de terceiros](THIRD_PARTY_NOTICES.md)

## Suporte e licença

Use [GitHub Issues](https://github.com/jianyintang/find-disk-killer/issues) para perguntas, bugs e sugestões. Relate vulnerabilidades em particular pelo [GitHub Security Advisories](https://github.com/jianyintang/find-disk-killer/security/advisories/new) e remova caminhos sensíveis, nomes de usuário e números de série de diagnósticos ou capturas.

FindDiskKiller é open source sob a [licença MIT](LICENSE).
