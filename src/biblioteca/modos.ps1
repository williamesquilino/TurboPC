# [parte] Modos (Recomendado, Escritório, Jogos, Máximo, Placa de vídeo) e o que cada um aplica
    # Rec = perfil Escritório; Game = perfil Jogos (nunca inclui o que mexe no Xbox)
    $GameIds = 'temp','wucache','browsercache','dumps','dns','thumbcache','appcache',
               'powerplan','startupdelay','gamedvr','suggestions','browserbg',
               'telemetry','adsid','activity','websearch','widgets','recall','cortana','feedback',
               'gamemode','mouseaccel','deliveryp2p','stickykeys','gpupref'
    if ($Global:HasNvidia) { $GameIds += 'nvidiadrv' }
    if ($Global:HasAmd)    { $GameIds += 'amddrv' }
    # ajustes de energia que gastam bateria: em notebook nunca entram sozinhos, só como extra
    $EnergyIds = 'powerplan', 'ultimate', 'powerthrottle'
    if ($Global:IsLaptop) { $GameIds = @($GameIds | Where-Object { $EnergyIds -notcontains $_ }) }
    foreach ($t in $TTasks) { $t | Add-Member -NotePropertyName Game -NotePropertyValue ($GameIds -contains $t.Id) }

    # o que o botão "Otimizar placa de vídeo" aplica
    $Global:GpuIds = @('gpupref') + @($(if ($Global:HasNvidia) { 'nvidiadrv' })) + @($(if ($Global:HasAmd) { 'amddrv' }))

    # Modos: o que cada um aplica (Ids) e o que oferece desligado na revisão (Extras)
    $Global:Modes = [ordered]@{
        # só o que melhora sem tirar nada que a pessoa use ou veja
        Recomendado = @{
            Ids    = @('temp','wucache','browsercache','dumps','dns','thumbcache','startupdelay','suggestions',
                       'telemetry','adsid','activity','websearch','widgets','recall','cortana','feedback','fileext','numlock','powerplan')
            Extras = @('appcache','gamedvr','browserbg','visualfx','transparency','cleanmgr','recycle')
        }
        Escritorio = @{
            Ids    = @($TTasks | Where-Object Rec | ForEach-Object Id)
            Extras = @('cleanmgr','recycle','bloat','backgroundapps','hibernate','copilot','thispc','classicmenu','taskbarleft','endtask')
        }
        Jogos = @{
            Ids    = @($GameIds)
            Extras = @('hags','gamepriority','ultimate','powerthrottle','shadercache','visualfx','transparency','cleanmgr','recycle','hibernate','copilot')
        }
        Maximo = @{
            Ids    = @($GameIds) + @('visualfx','transparency','backgroundapps','ultimate','powerthrottle')
            Extras = @('hags','gamepriority','hibernate','cleanmgr','shadercache','copilot','indexing','recycle')
        }
        Gpu = @{
            Ids    = @($Global:GpuIds)
            Extras = @('hags','gamemode','shadercache','ultimate','powerthrottle')
        }
    }
    if ($Global:IsLaptop) {
        foreach ($name in @($Global:Modes.Keys)) {
            $m = $Global:Modes[$name]
            # o Alto Desempenho vira opção em todos os modos (exceto Placa de vídeo), para notebook que vive na tomada
            $plan = if ($name -ne 'Gpu') { 'powerplan' }
            $m.Extras = @($m.Extras) + @($m.Ids | Where-Object { $EnergyIds -contains $_ }) + @($plan) | Where-Object { $_ } | Select-Object -Unique
            $m.Ids    = @($m.Ids | Where-Object { $EnergyIds -notcontains $_ })
        }
    }

    # na ordem das abas, sem repetidos e sem o que não existe
    function Get-ProfileIds([string]$Name) {
        $ids = $Global:Modes[$Name].Ids
        $TTasks | Where-Object { $ids -contains $_.Id } | ForEach-Object Id
    }
    function Get-ModeExtras([string]$Name) {
        $ids = $Global:Modes[$Name].Ids; $ex = $Global:Modes[$Name].Extras
        $TTasks | Where-Object { $ex -contains $_.Id -and $ids -notcontains $_.Id } | ForEach-Object Id
    }

