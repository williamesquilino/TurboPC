# TurboPC

Criado por **William Silva Esquilino**.

Otimizador para Windows 10/11 feito para PCs antigos de empresa.

## Como usar

1. Copie a pasta `TurboPC` para o PC (pendrive ou rede).
2. Baixe o **TurboPC.exe** na página de [Releases](https://github.com/williamesquilino/TurboPC/releases/latest), dê dois cliques e aceite o pedido de administrador.
3. No **Painel**, escolha um dos 4 **modos**. Abre uma tela em palavras simples: **o que vai acontecer**, **o que muda para você** e 1 a 5 perguntas sim/não (já marcadas com o mais indicado). Clique em **Otimizar agora**. Quem quiser ver a lista técnica clica em "Ver detalhes técnicos".
4. Reinicie o PC no final.
5. Ficou algo diferente do que queria? **Histórico > Desfazer**.

Se o Windows bloquear o arquivo ("Este arquivo veio de outro computador"), clique com o botão direito > Propriedades > marque **Desbloquear**.

## Modos

| Modo | Para quem | O que faz |
|---|---|---|
| **Recomendado** | Qualquer PC (o mais indicado) | Só ajustes invisíveis: limpeza, menos coisa rodando escondida, inicialização mais rápida, menos telemetria. **Nada some e nada muda de lugar** |
| **Escritório** | PC de trabalho | Recomendado + Windows mais leve (menos efeitos visuais) e serviços do Xbox desligados |
| **Jogos** | PC de jogos | Limpeza, Modo de Jogo, mouse sem aceleração, driver da placa de vídeo (só o que não tem efeito colateral). **Não mexe no Xbox nem no Game Pass** |
| **Máximo** | PC fraco que precisa de cada gota | Tudo do Jogos + visual simplificado, apps da Loja sem segundo plano e, em PC de mesa, energia no máximo |

### O TurboPC descobre para que o PC é usado

Na primeira vez que abre, o app procura **jogos instalados** (Steam, Epic, Riot e a lista de programas) e vê **quais programas a pessoa mais abre** (contador do próprio Windows). Depois pergunta **"Para que você usa este PC?"** com o palpite já destacado: Trabalho, Jogos competitivos, Jogos pesados ou Um pouco de tudo. A resposta fica salva em `C:\ProgramData\TurboPC\preferencias.json` e pode ser trocada no botão **Mudar** do Painel. Nada vai para a internet.

Com isso:

- o modo certo aparece como **"Indicado para este PC"**;
- com **jogo competitivo** (Valorant, CS2, Fortnite, LoL...), nada que possa baixar o FPS é aplicado e a tela avisa;
- com **jogos pesados numa RTX 4000/5000**, o agendamento de GPU (necessário para o DLSS Frame Generation) já vem ligado; com jogo competitivo, vem desligado;
- no modo **Escritório**, se tiver jogos no PC, a tela avisa que ele desliga o Xbox;
- as **escolhas feitas na tela de cada modo ficam lembradas** para a próxima vez.
### Identificação automática do PC

Acima dos modos o app mostra o que encontrou: **PC de mesa ou notebook**, disco, RAM, placa de vídeo, **plano de energia atual** e, em notebook, se está **na tomada ou na bateria** (com a porcentagem).

- **Notebook**: nenhum modo mexe na energia, para não acabar com a bateria. Os ajustes de energia (Alto Desempenho, Desempenho Máximo, limitação de energia) aparecem desligados nos Extras, para quem deixa o notebook sempre na tomada. Cada modo mostra o aviso "Notebook: energia fica de fora".
- **PC de mesa**: os modos colocam o plano em Alto Desempenho.
- O diagnóstico avisa quando o plano não combina com o PC (notebook na bateria em Alto Desempenho, PC de mesa em Economia de energia).

## Teste de FPS

No Painel, o cartão **Teste de FPS** mede o FPS de um jogo em 30 segundos, para ter certeza de que a otimização ajudou (e nunca atrapalhou):

1. Abra o jogo e vá para um lugar que dê para repetir depois (no Valorant, o The Range).
2. Clique em **Medir FPS**, depois em OK, e volte para o jogo. Em 10 segundos começa a medição (aviso sonoro no começo e no fim). Continue jogando.
3. O resultado mostra o **FPS médio** e o **1% mais baixo** (as travadinhas). O jogo é identificado sozinho.
4. Meça **antes e depois** de otimizar, no mesmo lugar. O TurboPC compara com a medição anterior do mesmo jogo:
   - melhorou (verde), ficou igual (até 3% é variação normal) ou caiu um pouco (amarelo, meça de novo);
   - **caiu 6% ou mais depois de uma otimização**: aviso em vermelho e botão **Desfazer** daquela otimização na hora.
5. Se o jogo estiver travado num limite de FPS (V-Sync ou limite do jogo, como 144), o app avisa que a comparação não vale e pede para tirar o limite antes de medir.

O medidor é o **PresentMon**, ferramenta gratuita e de código aberto da **Intel**. Ele é baixado sozinho pelo winget na primeira vez e lê os quadros pelo próprio Windows, sem tocar no jogo (não mexe com anti-cheat). As medições ficam em `C:\ProgramData\TurboPC\fps.json`.
## Desfazer

Antes de mudar qualquer coisa, o TurboPC guarda o valor antigo. Em **Histórico** aparece cada otimização feita (data, modo, quantas configurações mudaram) com o botão **Desfazer**, que volta tudo ao que era antes:

- configurações do registro (inclusive as que não existiam: são apagadas de novo);
- tipo de inicialização dos serviços;
- tarefas agendadas desligadas;
- plano de energia;
- hibernação.

O que não tem como voltar fica avisado antes de desfazer: arquivos apagados na limpeza (eram temporários), apps removidos (reinstale pela Microsoft Store), reset de rede e as configurações do driver NVIDIA (Painel de Controle NVIDIA > Gerenciar as configurações 3D > **Restaurar**).

Para voltar o PC inteiro de uma vez, use **Restauração do sistema** (botão no Histórico): por padrão o TurboPC cria um ponto de restauração antes de otimizar, **no máximo um por dia** (se já existe um das últimas 24 horas, ele é usado), para não encher o disco.

Os arquivos do desfazer ficam em `C:\ProgramData\TurboPC\desfazer`.

## O que tem

São 5 abas:

| Aba | O que tem |
|---|---|
| **Painel** | Nota de **Saúde do PC** (0 a 100) e diagnóstico. **Modos de otimização**. **Agora** (ao vivo): medidores de processador, memória, placa de vídeo e disco com "Tranquilo / Moderado / Pesado", gráfico da internet e armazenamento. Dados do PC e programas que mais pesam (com botão para encerrar). **Exportar relatório** gera um HTML na Área de Trabalho |
| **Espaço** | O que ocupa o disco: lixo para limpar, arquivos grandes, programas e jogos, pastas (veja abaixo) |
| **Personalizar** | 59 itens divididos em Limpeza, Desempenho, Jogos, Privacidade, Ajustes e Reparo, para escolher um por um |
| **Programas** | **Instalar programas** (mais de 50, via winget/Chocolatey, inclusive "atualizar todos") e **Inicialização** (o que abre junto com o Windows) |
| **Histórico** | Otimizações feitas com **Desfazer**, Restauração do sistema e o log da sessão |

Resumo das categorias de Personalizar:

- **Limpeza**: temporários, Windows Update, navegadores, miniaturas, Teams/Discord/Slack/Spotify/Steam, shaders, relatórios de erro, DNS, Lixeira, Limpeza de Disco completa (inclui Windows.old)
- **Desempenho**: plano de energia, efeitos visuais, transparência, atrasos de inicialização, Game Bar, serviços do Xbox, propaganda no Iniciar, Edge/Chrome em segundo plano, apps inúteis
- **Jogos**: Modo de Jogo, agendamento de GPU, prioridades, mouse, P2P, Teclas de Aderência, Desempenho Máximo, limitação de energia e **otimização da placa de vídeo**
- **Privacidade**: telemetria, anúncios, histórico, Bing, Widgets, Copilot, Recall, Cortana, feedback
- **Ajustes**: extensões de arquivo, Num Lock, Explorador, menu de clique direito, Iniciar à esquerda, "Finalizar tarefa"
- **Reparo**: SFC, DISM, WinSxS, chkdsk, TRIM, rede, Windows Update, fila de impressão, relógio, ícones

Cada item mostra em qual modo entra (`Recomendado`, `Escritório`, `Jogos`). Os que têm aviso em laranja explicam o efeito colateral.

## Espaço em disco

A aba **Espaço** mostra o que ocupa o disco e ajuda a liberar. A análise leva uns 15 a 60 segundos (usa o `robocopy` do Windows só para listar, sem copiar nada).

- **Resumo**: anel com o espaço livre e uma barra colorida dividindo o disco em Windows, Programas, Jogos, Seus arquivos, Dados de programas, Arquivos do sistema e Outros. Dá para escolher outra unidade nos botões do topo.
- **Dá para liberar agora**: temporários, atualizações já instaladas, cache de navegadores e de apps, relatórios de erro, instaladores de driver antigos (marcados em verde, seguros) e Lixeira, versão anterior do Windows, cache de shaders e hibernação (com aviso). Cada um mostra quanto ocupa e tem o botão **Limpar**; **Liberar o que é seguro** faz todos os verdes de uma vez.
- **Coisas escondidas que ocupam muito**: o que não aparece como programa instalado, mas costuma encher o disco. O app acha sozinho:
  - disco virtual do **Docker** (não diminui sozinho; botão para desinstalar o Docker Desktop) e Linux do **WSL** (botão que copia o comando para remover);
  - **máquinas virtuais** do VirtualBox/VMware, com a data do último uso;
  - **Minecraft** (CurseForge, FTB, Prism, .minecraft...);
  - **caches de programação** (npm, NuGet, pip, Gradle, Maven, Yarn, Cargo), com **Limpar** (baixam de novo quando precisar);
  - **logs gigantes** dentro do AppData;
  - **Windows extraído de uma ISO** (cópia do que já está na ISO);
  - espaço dos **pontos de restauração**, com botão para abrir a Proteção do Sistema e diminuir o limite.
- **Arquivos grandes**: arquivos de 500 MB ou mais nas pastas da pessoa, com a data da última modificação. **Apagar** manda para a Lixeira (dá para recuperar). Se o arquivo for maior que a Lixeira, o app avisa que vai apagar de vez antes de confirmar.
- **OneDrive**: arquivos que estão só na nuvem não aparecem (não ocupam o PC). Os que estão no PC ganham o botão **Deixar só na nuvem**, que libera o espaço sem apagar nada.
- **Programas e jogos que mais ocupam**, com **Desinstalar** (abre o desinstalador do fabricante; jogos da Steam abrem a desinstalação da Steam).
- **Pastas que mais ocupam**: clique numa pasta para entrar nela, **Voltar** para subir.

Por segurança, só dá para apagar dentro das pastas da pessoa (Downloads, Documentos, Área de Trabalho, Vídeos, pastas criadas por ela) e em outras unidades. Nunca no Windows, nos programas, no AppData, nas pastas de configuração (que começam com ".") nem nas bibliotecas de jogos. Para isso, use Desinstalar.
## Otimização da placa de vídeo

- **NVIDIA**: muda as configurações globais do driver (as mesmas do Painel de Controle NVIDIA > Gerenciar as configurações 3D), só no que não tem efeito colateral: energia em "Preferir desempenho máximo", filtragem de textura em "Alto desempenho" e taxa de atualização "Mais alta disponível". Usa o **NVIDIA Profile Inspector**, baixado sozinho pelo winget na primeira vez.
- **Ficam de fora de propósito**: o modo de baixa latência do driver (em jogo que depende do processador, como Valorant e CS2, ele **derruba o FPS**; use o **NVIDIA Reflex** dentro do jogo), o tamanho do cache de shaders (mudar pode fazer os jogos recompilarem tudo) e o agendamento de GPU por hardware (pode baixar o FPS em alguns jogos; fica como extra opcional, útil para DLSS Frame Generation).
- **AMD**: deixa o cache de shaders sempre ligado (com backup em `C:\ProgramData\TurboPC\backup`). A AMD não documenta as outras chaves do driver, então o resto deve ser ligado no próprio AMD Software (Alt+R): **HYPR-RX** (Anti-Lag + Radeon Boost).
- **Qualquer placa**: jogos da Steam e da Epic marcados como "Alto desempenho" (em notebook, usam a placa dedicada e não o vídeo integrado) e as otimizações para jogos em janela do Windows 11.

## Instalar programas: winget e Chocolatey

- O **winget** já vem no Windows 10 (versão 1809 ou mais nova) e no 11. Se não estiver no PC, o app mostra o botão **Instalar winget**, que abre a Microsoft Store no "Instalador de Aplicativo".
- O **Chocolatey** é opcional. Se ligar "Usar o Chocolatey se o winget falhar", ele tenta pelo Chocolatey quando o winget não consegue. O botão **Instalar Chocolatey** instala ele pelo próprio winget.
- Os programas vêm sempre do site oficial de cada fabricante, na versão mais nova.

## O que ele NÃO faz (de propósito)

- Não desliga o Windows Update, o Defender nem o Firewall.
- Não mexe em arquivos de usuários, senhas ou favoritos.
- Não aplica "tweaks milagrosos" de registro que não têm efeito real ou deixam o sistema instável.

## PC de empresa (domínio) e senha de admin do técnico

Quando o funcionário está logado e o técnico digita a senha de admin dele, o TurboPC roda como o técnico, mas:

- os **ajustes de usuário** (visual, mouse, Iniciar, extensões, Num Lock...) vão para **quem está logado na tela**, não para a conta do técnico;
- a aba **Inicialização** mostra e muda os programas do funcionário;
- os **programas** são instalados **para todos os usuários do PC** (se um programa não aceitar, ele instala só para o usuário atual);
- o **relatório** vai para a Área de Trabalho do funcionário, com uma cópia em `C:\ProgramData\TurboPC\relatorios`;
- a detecção de uso olha os programas que **o funcionário** mais usa;
- o Painel mostra no topo "aplicado por (admin) no usuário (funcionário)".

O **Desfazer** volta os ajustes do funcionário se ele estiver logado. Se não estiver, o app avisa para entrar com esse usuário e desfazer de novo.

Em **PC no domínio**, as políticas da empresa (GPO) mandam no que configuram. Os ajustes de política do Edge/Chrome e de atualizações entre PCs ficam **fora dos modos** (aparecem só como extras), porque costumam ser definidos pela TI. Sem ninguém logado na tela (acesso remoto ou modo sem janela por GPO/RMM), os ajustes de usuário vão para a conta que executou, e o log avisa.
## Vários PCs de uma vez (sem janela)

```
powershell -ExecutionPolicy Bypass -File TurboPC.ps1 -Auto
powershell -ExecutionPolicy Bypass -File TurboPC.ps1 -Auto -Perfil Jogos
powershell -ExecutionPolicy Bypass -File TurboPC.ps1 -Auto -Tasks temp,wucache,dns,visualfx
powershell -ExecutionPolicy Bypass -File TurboPC.ps1 -List
```

`-Perfil` aceita `Recomendado` (padrão), `Escritorio`, `Jogos`, `Maximo` e `Gpu`. `-NoRestorePoint` pula o ponto de restauração. As execuções sem janela também ficam no Histórico e podem ser desfeitas pela interface.

## Baixar e atualizar

Baixe os `.exe` na página de **[Releases](https://github.com/williamesquilino/TurboPC/releases/latest)**:

- **TurboPC.exe**: abre a interface. Sempre pede administrador.
- **TurboPC-Auto-Recomendado.exe**, **TurboPC-Auto-Escritorio.exe**, **TurboPC-Auto-Jogos.exe**: aplicam o modo direto, sem interface. Aceitam `-Tasks`, `-NoRestorePoint` e `-NoPause` (para não esperar Enter no final, útil em RMM/GPO).

**Atualização automática:** ao abrir, o TurboPC confere se há versão nova aqui no GitHub. Se tiver, aparece **Atualizar para vX** na barra lateral: ele mostra o que mudou, baixa os `.exe` novos (conferindo o SHA-256 publicado pelo GitHub), troca os arquivos e abre de novo sozinho. Também dá para clicar em **Procurar atualização** a qualquer momento.

## Para quem mexe no código

O código fica na pasta **`src/`**, dividido por assunto. O `TurboPC.ps1` da raiz é **gerado** a partir dela: não edite ele direto.

| Pasta | O que tem |
|---|---|
| `src/core/` | Cabeçalho e parâmetros, pedido de administrador, modo sem janela (`-Auto`, `-List`) |
| `src/biblioteca/` | As otimizações, uma categoria por arquivo (`tarefas-limpeza.ps1`, `tarefas-jogos.ps1`...), os modos e o desfazer. É o que roda tanto na interface quanto no modo sem janela |
| `src/interface/` | A interface: Painel, monitor, Espaço, Teste de FPS, programas, histórico, atualização, eventos |
| `src/interface/xaml/` | O visual de cada aba (XAML) |
| `src/TurboPC.main.ps1` | A ordem em que as partes são juntadas |

Cada arquivo começa com uma linha `# [parte] ...` explicando o que tem nele (essa linha não vai para o arquivo final).

- **Gerar o `TurboPC.ps1`** depois de mudar algo em `src/`: `powershell -ExecutionPolicy Bypass -File build.ps1 -SoGerar` (confere a sintaxe também).
- **Compilar os `.exe`** localmente: `powershell -ExecutionPolicy Bypass -File build.ps1` (precisa do módulo `ps2exe`).
- **Publicar uma versão:** troque o `$AppVersion` em `src/core/cabecalho.ps1`, rode o `build.ps1 -SoGerar`, faça o commit e envie uma tag com o mesmo número (ex.: `git tag v1.9.0` e `git push origin v1.9.0`). O GitHub Actions compila os `.exe` e publica a release; os PCs com TurboPC recebem a atualização.
- A cada envio, o GitHub confere se o `TurboPC.ps1` está igual ao que a pasta `src/` gera (checagem `Checagem`).
