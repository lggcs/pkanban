# PowerShell Kanban Board Server
param(
    [int]$Port = 8080,
    [string]$DataFile = "kanban_data.json",
    [switch]$Help
)

if ($Help) {
    Write-Host @"
========================================
Kanban Board Server - Usage
========================================

Serves the Kanban Board web interface and API.

PARAMETERS:
  -Port       <int>       (Optional) HTTP port to listen on (default: 8080)
  -DataFile   <string>    (Optional) JSON data file path (default: kanban_data.json)
  -Help                   (Optional) Show this help message

EXAMPLES:
  # Default usage (port 8080, kanban_data.json)
  .\server.ps1

  # Custom port
  .\server.ps1 -Port 3000

  # Custom data file
  .\server.ps1 -DataFile "myboard.json"

DASHBOARD:
  Open http://127.0.0.1:$Port in your browser after starting

========================================
"@ -ForegroundColor Cyan
    exit 0
}

$ErrorActionPreference = "Stop"

# Resolve data file path
if ([System.IO.Path]::IsPathRooted($DataFile)) {
    $dataFilePath = $DataFile
} else {
    $dataFilePath = Join-Path $PSScriptRoot $DataFile
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Kanban Board Server" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Data file: $dataFilePath" -ForegroundColor Gray
Write-Host "Port: $Port" -ForegroundColor Gray
Write-Host ""

# Helper: Validate color (prevent injection)
function Test-Color {
    param($color)
    if (-not $color) { return '#6366f1' }
    if ($color -match '^#[0-9A-Fa-f]{3}$') { return $color }
    if ($color -match '^#[0-9A-Fa-f]{6}$') { return $color }
    if ($color -match '^rgba?\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*(,\s*(0|1|0?\.\d+))?\s*\)$') { return $color }
    return '#6366f1'
}

# Helper: Convert to JSON properly
function Convert-ToJsonString($obj) {
    try {
        if ($null -eq $obj) {
            return 'null'
        }
        $json = $obj | ConvertTo-Json -Depth 10 -Compress
        # Fix: PowerShell 5.x returns single object instead of array for single-item arrays
        if ($obj -is [Array] -and $json -and -not $json.TrimStart().StartsWith('[')) {
            $json = '[' + $json + ']'
        }
        return $json
    }
    catch {
        Write-Host "JSON error: $_" -ForegroundColor Red
        return '{}'
    }
}

# Helper: Convert PSCustomObject to Hashtable (recursive)
function ConvertToHashtable($obj) {
    if ($obj -is [PSCustomObject]) {
        $ht = @{}
        foreach ($prop in $obj.PSObject.Properties) {
            $ht[$prop.Name] = ConvertToHashtable $prop.Value
        }
        return $ht
    }
    elseif ($obj -is [Array]) {
        return @($obj | ForEach-Object { ConvertToHashtable $_ })
    }
    else {
        return $obj
    }
}

# Initialize data structures - use ArrayLists for mutable collections
# We use a global hashtable to store all data to avoid PowerShell scoping issues
$global:KanbanData = @{
    columns = [System.Collections.ArrayList]::new()
    tags = [System.Collections.ArrayList]::new()
    cards = @{}
    nextCardId = 1
    nextTagId = 6
}

function Load-Data {
    if (Test-Path $dataFilePath) {
        try {
            $jsonContent = [System.IO.File]::ReadAllText($dataFilePath, [System.Text.Encoding]::UTF8)
            $data = $jsonContent | ConvertFrom-Json

            # Convert columns - use ArrayList
            $global:KanbanData.columns = [System.Collections.ArrayList]::new()
            if ($data.columns) {
                foreach ($col in $data.columns) {
                    [void]$global:KanbanData.columns.Add(@{
                        id = $col.id
                        name = $col.name
                        position = $col.position
                        color = $col.color
                    })
                }
            }
            Write-Host "  Loaded $($global:KanbanData.columns.Count) columns" -ForegroundColor DarkGray

            # Convert tags - use ArrayList
            $global:KanbanData.tags = [System.Collections.ArrayList]::new()
            if ($data.tags) {
                foreach ($tag in $data.tags) {
                    [void]$global:KanbanData.tags.Add(@{
                        id = $tag.id
                        name = $tag.name
                        color = $tag.color
                    })
                }
            }
            Write-Host "  Loaded $($global:KanbanData.tags.Count) tags" -ForegroundColor DarkGray

            # Convert cards - use hashtable
            $global:KanbanData.cards = @{}
            if ($data.cards) {
                foreach ($prop in $data.cards.PSObject.Properties) {
                    $card = $prop.Value
                    $global:KanbanData.cards[$prop.Name] = @{
                        id = $card.id
                        title = $card.title
                        description = $card.description
                        column = $card.column
                        position = $card.position
                        start_date = $card.start_date
                        end_date = $card.end_date
                        created_at = $card.created_at
                        tags = @($card.tags)
                        checklist = @()
                    }
                    # Handle checklist
                    if ($card.checklist) {
                        $global:KanbanData.cards[$prop.Name].checklist = @($card.checklist | ForEach-Object {
                            @{
                                id = $_.id
                                text = $_.text
                                completed = $_.completed
                                position = $_.position
                            }
                        })
                    }
                }
            }
            Write-Host "  Loaded $($global:KanbanData.cards.Count) cards" -ForegroundColor DarkGray

            $global:KanbanData.nextCardId = if ($data.nextCardId) { $data.nextCardId } else { 1 }
            $global:KanbanData.nextTagId = if ($data.nextTagId) { $data.nextTagId } else { 6 }

            Write-Host "Data loaded from: $dataFilePath" -ForegroundColor Green
        }
        catch {
            Write-Host "Error loading data, creating new: $_" -ForegroundColor Yellow
            Initialize-DefaultData
        }
    }
    else {
        Write-Host "Creating new data file: $dataFilePath" -ForegroundColor Yellow
        Initialize-DefaultData
        Save-Data
    }
}

function Initialize-DefaultData {
    $global:KanbanData.columns = [System.Collections.ArrayList]::new()
    [void]$global:KanbanData.columns.Add(@{ id = 'todo'; name = 'To Do'; position = 0; color = '#f472b6' })
    [void]$global:KanbanData.columns.Add(@{ id = 'progress'; name = 'In Progress'; position = 1; color = '#60a5fa' })
    [void]$global:KanbanData.columns.Add(@{ id = 'done'; name = 'Done'; position = 2; color = '#4ade80' })
    
    $global:KanbanData.tags = [System.Collections.ArrayList]::new()
    [void]$global:KanbanData.tags.Add(@{ id = 1; name = 'Bug'; color = '#ef4444' })
    [void]$global:KanbanData.tags.Add(@{ id = 2; name = 'Feature'; color = '#22c55e' })
    [void]$global:KanbanData.tags.Add(@{ id = 3; name = 'Enhancement'; color = '#3b82f6' })
    [void]$global:KanbanData.tags.Add(@{ id = 4; name = 'Urgent'; color = '#f97316' })
    [void]$global:KanbanData.tags.Add(@{ id = 5; name = 'Documentation'; color = '#8b5cf6' })
    
    $global:KanbanData.cards = @{}
    $global:KanbanData.nextCardId = 1
    $global:KanbanData.nextTagId = 6
    
    Write-Host "  Initialized: $($global:KanbanData.columns.Count) columns, $($global:KanbanData.tags.Count) tags" -ForegroundColor DarkGray
}

function Save-Data {
    try {
        Write-Host "  [Save-Data] Saving..." -ForegroundColor DarkGray
        
        # Build cards object for JSON
        $cardsObj = @{}
        if ($null -ne $global:KanbanData.cards -and $global:KanbanData.cards.Count -gt 0) {
            foreach ($key in $global:KanbanData.cards.Keys) {
                $cardsObj[$key] = @{
                    id = $global:KanbanData.cards[$key].id
                    title = $global:KanbanData.cards[$key].title
                    description = $global:KanbanData.cards[$key].description
                    column = $global:KanbanData.cards[$key].column
                    position = $global:KanbanData.cards[$key].position
                    start_date = $global:KanbanData.cards[$key].start_date
                    end_date = $global:KanbanData.cards[$key].end_date
                    created_at = $global:KanbanData.cards[$key].created_at
                    tags = @($global:KanbanData.cards[$key].tags)
                    checklist = @($global:KanbanData.cards[$key].checklist)
                }
            }
        }

        # Convert ArrayLists to arrays for JSON serialization
        $columnsArray = @($global:KanbanData.columns)
        $tagsArray = @($global:KanbanData.tags)

        $data = @{
            columns = $columnsArray
            tags = $tagsArray
            cards = $cardsObj
            nextCardId = $global:KanbanData.nextCardId
            nextTagId = $global:KanbanData.nextTagId
        }

        $json = Convert-ToJsonString $data
        Write-Host "  [Save-Data] Writing to: $dataFilePath" -ForegroundColor DarkGray
        [System.IO.File]::WriteAllText($dataFilePath, $json, [System.Text.Encoding]::UTF8)
        Write-Host "  [Save-Data] Done. Columns: $($global:KanbanData.columns.Count), Cards: $($global:KanbanData.cards.Count)" -ForegroundColor DarkGray
    }
    catch {
        Write-Host "Error saving data: $_" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
    }
}

# Load data on startup
Load-Data

function Test-IsAdmin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$currentUser
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-LocalIPAddresses {
    $ips = @()
    try {
        # Try Get-NetIPAddress first (PowerShell 3+)
        $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
               Where-Object { $_.IPAddress -notlike '127.*' -and $_.PrefixOrigin -ne 'WellKnown' } | 
               Select-Object -ExpandProperty IPAddress
    }
    catch { }
    
    # Fallback to WMI if Get-NetIPAddress returns nothing
    if (-not $ips -or $ips.Count -eq 0) {
        try {
            $ips = Get-WmiObject -Class Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue | 
                   Where-Object { $_.IPEnabled -eq $true } | 
                   ForEach-Object { $_.IPAddress } | 
                   Where-Object { $_ -notlike '127.*' -and $_ -notlike '*:*' }
        }
        catch { }
    }
    
    return @($ips | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-ComputerName {
    try {
        return $env:COMPUTERNAME
    }
    catch {
        return $null
    }
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Kanban Board Server is now running!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan

# Bind to all interfaces if running as admin, otherwise localhost only
$isAdmin = Test-IsAdmin
$listener = [System.Net.HttpListener]::new()

if ($isAdmin) {
    # Bind to all interfaces when running as admin
    $listener.Prefixes.Add("http://+:$Port/")
    $localIPs = Get-LocalIPAddresses
    $computerName = Get-ComputerName
    
    Write-Host "Running as Administrator - accessible over network" -ForegroundColor Yellow
    Write-Host "Local access:   http://127.0.0.1:$Port" -ForegroundColor White
    if ($computerName) {
        Write-Host "Hostname:       http://${computerName}:$Port" -ForegroundColor Cyan
    }
    if ($localIPs -and $localIPs.Count -gt 0) {
        foreach ($ip in $localIPs) {
            Write-Host "Network access: http://${ip}:$Port" -ForegroundColor Green
        }
    }
}
else {
    # Localhost only when not admin
    $listener.Prefixes.Add("http://127.0.0.1:$Port/")
    Write-Host "Local access:  http://127.0.0.1:$Port" -ForegroundColor White
    Write-Host "(Run as Admin to enable network access)" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Press Ctrl+C to stop the server" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$listener.Start()

$requestCount = 0
$stopServer = $false

try {
    while ($listener.IsListening) {
        # Use async with timeout to allow Ctrl+C to interrupt
        $asyncResult = $listener.BeginGetContext($null, $null)
        
        # Wait up to 500ms, then check again (allows Ctrl+C to be processed)
        while (-not $asyncResult.AsyncWaitHandle.WaitOne(500)) {
            # Loop continues, checking for requests every 500ms
            # Ctrl+C will break out of this wait
        }
        
        $context = $listener.EndGetContext($asyncResult)
        $request = $context.Request
        $response = $context.Response

        $requestCount++
        $url = $request.Url.LocalPath
        $queryString = $request.Url.Query

        if ($requestCount -le 10 -or $requestCount % 100 -eq 0) {
            Write-Host "[$requestCount] $($request.HttpMethod) $url" -ForegroundColor Gray
        }

        try {
            $responseData = ""
            $contentType = "application/json"
            $statusCode = 200

            # Parse query parameters
            $queryParams = @{}
            if ($queryString.Length -gt 0) {
                $qs = $queryString.Substring(1).Split('&')
                foreach ($param in $qs) {
                    $parts = $param.Split('=')
                    if ($parts.Length -eq 2) {
                        $key = [System.Web.HttpUtility]::UrlDecode($parts[0])
                        $val = [System.Web.HttpUtility]::UrlDecode($parts[1])
                        $queryParams[$key] = $val
                    }
                }
            }

            # Read request body for POST/PUT
            $body = $null
            if ($request.HttpMethod -in @('POST', 'PUT')) {
                $reader = New-Object System.IO.StreamReader($request.InputStream)
                $bodyText = $reader.ReadToEnd()
                $reader.Close()
                try {
                    $body = $bodyText | ConvertFrom-Json
                }
                catch {
                    $body = @{}
                }
            }

            # Route: Serve index.html
            if ($url -eq "/" -or $url -eq "/index.html") {
                $htmlPath = Join-Path $PSScriptRoot "index.html"
                if (Test-Path $htmlPath) {
                    $responseData = [System.IO.File]::ReadAllText($htmlPath)
                    $contentType = "text/html"
                } else {
                    $statusCode = 404
                    $responseData = '{"error": "HTML file not found"}'
                }
            }

            # Route: GET /api/columns
            elseif ($url -eq "/api/columns" -and $request.HttpMethod -eq "GET") {
                $columns = @()
                if ($null -ne $global:KanbanData.columns) {
                    foreach ($col in $global:KanbanData.columns) {
                        $cardCount = 0
                        if ($null -ne $global:KanbanData.cards) {
                            foreach ($cardId in $global:KanbanData.cards.Keys) {
                                if ($global:KanbanData.cards[$cardId].column -eq $col.id) {
                                    $cardCount++
                                }
                            }
                        }
                        $columns += @{
                            id = $col.id
                            name = $col.name
                            position = $col.position
                            color = $col.color
                            card_count = $cardCount
                        }
                    }
                }
                # Ensure we always return an array
                if ($columns.Count -eq 0) {
                    $responseData = '[]'
                } else {
                    $responseData = Convert-ToJsonString @($columns)
                }
            }

            # Route: POST /api/columns
            elseif ($url -eq "/api/columns" -and $request.HttpMethod -eq "POST") {
                Write-Host "  [DEBUG] columns type: $($global:KanbanData.columns.GetType().FullName)" -ForegroundColor DarkGray
                Write-Host "  [DEBUG] columns count: $($global:KanbanData.columns.Count)" -ForegroundColor DarkGray
                
                $colId = if ($body.id) { $body.id } else { [Guid]::NewGuid().ToString().Substring(0, 8) }
                $colName = if ($body.name) { $body.name } else { "New Column" }
                $colColor = Test-Color $body.color

                $maxPos = -1
                foreach ($col in $global:KanbanData.columns) {
                    if ($col.position -gt $maxPos) { $maxPos = $col.position }
                }

                $newCol = @{
                    id = $colId
                    name = $colName
                    position = $maxPos + 1
                    color = $colColor
                }

                Write-Host "  [DEBUG] Adding column..." -ForegroundColor DarkGray
                [void]$global:KanbanData.columns.Add($newCol)
                Save-Data

                $newCol['card_count'] = 0
                $responseData = Convert-ToJsonString $newCol
                $statusCode = 201
            }

            # Route: PUT /api/columns/reorder
            elseif ($url -eq "/api/columns/reorder" -and $request.HttpMethod -eq "PUT") {
                foreach ($item in $body) {
                    foreach ($col in $global:KanbanData.columns) {
                        if ($col.id -eq $item.id) {
                            $col.position = $item.position
                            break
                        }
                    }
                }
                Save-Data
                $responseData = '{"success":true}'
            }

            # Route: PUT /api/columns/move-cards
            elseif ($url -eq "/api/columns/move-cards" -and $request.HttpMethod -eq "PUT") {
                $fromCol = $body.from_column
                $toCol = $body.to_column
                
                foreach ($cardId in $global:KanbanData.cards.Keys) {
                    if ($global:KanbanData.cards[$cardId].column -eq $fromCol) {
                        $global:KanbanData.cards[$cardId].column = $toCol
                    }
                }
                Save-Data
                $responseData = '{"success":true}'
            }

            # Route: PUT /api/columns/:id
            elseif ($url -match '^/api/columns/([^/]+)$' -and $request.HttpMethod -eq "PUT") {
                $colId = $url.Split('/')[3]
                
                foreach ($col in $global:KanbanData.columns) {
                    if ($col.id -eq $colId) {
                        if ($body.name) { $col.name = $body.name }
                        if ($body.color) { $col.color = Test-Color $body.color }
                        if ($body.position -ne $null) { $col.position = $body.position }
                        break
                    }
                }
                Save-Data
                
                # Return updated column
                $foundCol = $null
                foreach ($col in $global:KanbanData.columns) {
                    if ($col.id -eq $colId) {
                        $foundCol = @{
                            id = $col.id
                            name = $col.name
                            position = $col.position
                            color = $col.color
                        }
                        break
                    }
                }
                $responseData = Convert-ToJsonString $foundCol
            }

            # Route: DELETE /api/columns/:id
            elseif ($url -match '^/api/columns/([^/]+)$' -and $request.HttpMethod -eq "DELETE") {
                $colId = $url.Split('/')[3]

                # Check for cards in column
                $cardCount = 0
                foreach ($cardId in $global:KanbanData.cards.Keys) {
                    if ($global:KanbanData.cards[$cardId].column -eq $colId) {
                        $cardCount++
                    }
                }

                if ($cardCount -gt 0) {
                    $statusCode = 400
                    $responseData = "{`"error`":`"Column has cards`",`"card_count`":$cardCount}"
                }
                else {
                    # Remove column using ArrayList RemoveAt
                    $idxToRemove = -1
                    for ($i = 0; $i -lt $global:KanbanData.columns.Count; $i++) {
                        if ($global:KanbanData.columns[$i].id -eq $colId) {
                            $idxToRemove = $i
                            break
                        }
                    }
                    if ($idxToRemove -ge 0) {
                        $global:KanbanData.columns.RemoveAt($idxToRemove)
                    }
                    Save-Data
                    $responseData = '{"success":true}'
                }
            }

            # Route: GET /api/tags
            elseif ($url -eq "/api/tags" -and $request.HttpMethod -eq "GET") {
                if ($null -eq $global:KanbanData.tags -or $global:KanbanData.tags.Count -eq 0) {
                    $responseData = '[]'
                } else {
                    $responseData = Convert-ToJsonString @($global:KanbanData.tags)
                }
            }

            # Route: POST /api/tags
            elseif ($url -eq "/api/tags" -and $request.HttpMethod -eq "POST") {
                $tagName = if ($body.name) { $body.name } else { "New Tag" }
                $tagColor = Test-Color $body.color

                # Check for duplicate
                $duplicate = $false
                foreach ($tag in $global:KanbanData.tags) {
                    if ($tag.name -eq $tagName) {
                        $duplicate = $true
                        break
                    }
                }

                if ($duplicate) {
                    $statusCode = 400
                    $responseData = '{"error":"Tag already exists"}'
                }
                else {
                    $newTag = @{
                        id = $global:KanbanData.nextTagId
                        name = $tagName
                        color = $tagColor
                    }
                    [void]$global:KanbanData.tags.Add($newTag)
                    $global:KanbanData.nextTagId++
                    Save-Data

                    $responseData = Convert-ToJsonString $newTag
                    $statusCode = 201
                }
            }

            # Route: DELETE /api/tags/:id
            elseif ($url -match '^/api/tags/(\d+)$' -and $request.HttpMethod -eq "DELETE") {
                $tagId = [int]$url.Split('/')[3]

                # Remove tag using ArrayList RemoveAt
                $idxToRemove = -1
                for ($i = 0; $i -lt $global:KanbanData.tags.Count; $i++) {
                    if ($global:KanbanData.tags[$i].id -eq $tagId) {
                        $idxToRemove = $i
                        break
                    }
                }
                if ($idxToRemove -ge 0) {
                    $global:KanbanData.tags.RemoveAt($idxToRemove)
                }

                # Remove tag from cards
                foreach ($cardId in $global:KanbanData.cards.Keys) {
                    $card = $global:KanbanData.cards[$cardId]
                    if ($card.tags) {
                        $newCardTags = @()
                        foreach ($t in $card.tags) {
                            if ($t -ne $tagId) {
                                $newCardTags += $t
                            }
                        }
                        $card.tags = $newCardTags
                    }
                }
                
                Save-Data
                $responseData = '{"success":true}'
            }

            # Route: GET /api/cards
            elseif ($url -eq "/api/cards" -and $request.HttpMethod -eq "GET") {
                $cardsObj = @{}
                if ($null -ne $global:KanbanData.cards) {
                    foreach ($cardId in $global:KanbanData.cards.Keys) {
                        $card = $global:KanbanData.cards[$cardId]
                        $cardsObj[$cardId] = @{
                            id = $card.id
                            title = $card.title
                            description = $card.description
                            column = $card.column
                            position = $card.position
                            start_date = $card.start_date
                            end_date = $card.end_date
                            created_at = $card.created_at
                            tags = @($card.tags | ForEach-Object {
                                foreach ($t in $global:KanbanData.tags) {
                                    if ($t.id -eq $_) {
                                        return @{ id = $t.id; name = $t.name; color = $t.color }
                                    }
                                }
                            })
                            checklist = @($card.checklist)
                        }
                    }
                }
                $responseData = Convert-ToJsonString $cardsObj
            }

            # Route: GET /api/cards/:id
            elseif ($url -match '^/api/cards/(\d+)$' -and $request.HttpMethod -eq "GET") {
                $cardId = $url.Split('/')[3]
                
                if ($global:KanbanData.cards.ContainsKey($cardId)) {
                    $card = $global:KanbanData.cards[$cardId]
                    $cardData = @{
                        id = $card.id
                        title = $card.title
                        description = $card.description
                        column = $card.column
                        position = $card.position
                        start_date = $card.start_date
                        end_date = $card.end_date
                        created_at = $card.created_at
                        tags = @($card.tags | ForEach-Object {
                            foreach ($t in $global:KanbanData.tags) {
                                if ($t.id -eq $_) {
                                    return @{ id = $t.id; name = $t.name; color = $t.color }
                                }
                            }
                        })
                        checklist = @($card.checklist)
                    }
                    $responseData = Convert-ToJsonString $cardData
                }
                else {
                    $statusCode = 404
                    $responseData = '{"error":"Card not found"}'
                }
            }

            # Route: POST /api/cards
            elseif ($url -eq "/api/cards" -and $request.HttpMethod -eq "POST") {
                $cardId = $global:KanbanData.nextCardId

                $column = if ($body.column) { $body.column } else { "todo" }

                # Get max position in column
                $maxPos = -1
                if ($null -ne $global:KanbanData.cards -and $global:KanbanData.cards.Count -gt 0) {
                    foreach ($cid in $global:KanbanData.cards.Keys) {
                        $c = $global:KanbanData.cards[$cid]
                        if ($c.column -eq $column -and $c.position -gt $maxPos) {
                            $maxPos = $c.position
                        }
                    }
                }

                # Handle tags array
                $cardTags = @()
                if ($body.tags) {
                    foreach ($tag in $body.tags) {
                        if ($tag) {
                            $cardTags += [int]$tag
                        }
                    }
                }

                $newCard = @{
                    id = $cardId
                    title = if ($body.title) { $body.title } else { "New Card" }
                    description = if ($body.description) { $body.description } else { "" }
                    column = $column
                    position = $maxPos + 1
                    start_date = $body.start_date
                    end_date = $body.end_date
                    created_at = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                    tags = $cardTags
                    checklist = @()
                }

                # Add checklist items if provided
                if ($body.checklist) {
                    foreach ($item in $body.checklist) {
                        $newCard.checklist += @{
                            id = $cardId * 100 + $newCard.checklist.Count + 1
                            text = $item.text
                            completed = if ($item.completed) { $item.completed } else { 0 }
                            position = $newCard.checklist.Count
                        }
                    }
                }

                # Initialize cards hashtable if needed
                if ($null -eq $global:KanbanData.cards) {
                    $global:KanbanData.cards = @{}
                }

                # Add card to hashtable
                $global:KanbanData.cards["$cardId"] = $newCard
                $global:KanbanData.nextCardId++
                Save-Data

                $responseData = Convert-ToJsonString $newCard
                $statusCode = 201
            }

            # Route: PUT /api/cards/:id
            elseif ($url -match '^/api/cards/(\d+)$' -and $request.HttpMethod -eq "PUT") {
                $cardId = $url.Split('/')[3]
                
                if ($global:KanbanData.cards.ContainsKey($cardId)) {
                    $card = $global:KanbanData.cards[$cardId]
                    
                    if ($body.title -ne $null) { $card.title = $body.title }
                    if ($body.description -ne $null) { $card.description = $body.description }
                    if ($body.column -ne $null) { $card.column = $body.column }
                    if ($body.position -ne $null) { $card.position = $body.position }
                    if ($body.start_date -ne $null) { $card.start_date = $body.start_date }
                    if ($body.end_date -ne $null) { $card.end_date = $body.end_date }
                    if ($body.tags -ne $null) { $card.tags = @($body.tags | Where-Object { $_ }) }
                    if ($body.checklist -ne $null) { $card.checklist = @($body.checklist) }
                    
                    Save-Data
                    
                    $cardData = @{
                        id = $card.id
                        title = $card.title
                        description = $card.description
                        column = $card.column
                        position = $card.position
                        start_date = $card.start_date
                        end_date = $card.end_date
                        tags = @($card.tags | ForEach-Object {
                            foreach ($t in $global:KanbanData.tags) {
                                if ($t.id -eq $_) {
                                    return @{ id = $t.id; name = $t.name; color = $t.color }
                                }
                            }
                        })
                        checklist = @($card.checklist)
                    }
                    $responseData = Convert-ToJsonString $cardData
                }
                else {
                    $statusCode = 404
                    $responseData = '{"error":"Card not found"}'
                }
            }

            # Route: DELETE /api/cards/:id
            elseif ($url -match '^/api/cards/(\d+)$' -and $request.HttpMethod -eq "DELETE") {
                $cardId = $url.Split('/')[3]
                
                $global:KanbanData.cards.Remove($cardId)
                Save-Data
                
                $responseData = '{"success":true}'
            }

            # Route: PUT /api/reorder
            elseif ($url -eq "/api/reorder" -and $request.HttpMethod -eq "PUT") {
                foreach ($item in $body) {
                    $cardId = "$($item.id)"
                    if ($global:KanbanData.cards.ContainsKey($cardId)) {
                        $card = $global:KanbanData.cards[$cardId]
                        $card.column = $item.column
                        $card.position = $item.position
                    }
                }
                Save-Data
                $responseData = '{"success":true}'
            }

            # Route: PUT /api/cards/bulk-move
            elseif ($url -eq "/api/cards/bulk-move" -and $request.HttpMethod -eq "PUT") {
                $cardId = "$($body.cardId)"
                $newColumn = $body.column
                $newPosition = $body.position
                
                if ($global:KanbanData.cards.ContainsKey($cardId)) {
                    $card = $global:KanbanData.cards[$cardId]
                    $oldColumn = $card.column
                    $oldPosition = $card.position
                    
                    # Shift cards in old column
                    foreach ($cid in $global:KanbanData.cards.Keys) {
                        $c = $global:KanbanData.cards[$cid]
                        if ($c.column -eq $oldColumn -and $c.position -gt $oldPosition) {
                            $c.position--
                        }
                    }
                    
                    # Make room in new column
                    foreach ($cid in $global:KanbanData.cards.Keys) {
                        $c = $global:KanbanData.cards[$cid]
                        if ($c.column -eq $newColumn -and $c.position -ge $newPosition) {
                            $c.position++
                        }
                    }
                    
                    # Move card
                    $card.column = $newColumn
                    $card.position = $newPosition
                    
                    Save-Data
                    $responseData = '{"success":true}'
                }
                else {
                    $statusCode = 404
                    $responseData = '{"error":"Card not found"}'
                }
            }

            # Route: POST /api/cards/:id/checklist
            elseif ($url -match '^/api/cards/(\d+)/checklist$' -and $request.HttpMethod -eq "POST") {
                $cardId = $url.Split('/')[3]
                
                if ($global:KanbanData.cards.ContainsKey($cardId)) {
                    $card = $global:KanbanData.cards[$cardId]
                    
                    $maxPos = -1
                    foreach ($item in $card.checklist) {
                        if ($item.position -gt $maxPos) { $maxPos = $item.position }
                    }
                    
                    $newItem = @{
                        id = [int]$cardId * 1000 + ($card.checklist.Count + 1)
                        text = if ($body.text) { $body.text } else { "" }
                        completed = if ($body.completed) { $body.completed } else { 0 }
                        position = $maxPos + 1
                    }
                    
                    $card.checklist += $newItem
                    Save-Data
                    
                    $responseData = Convert-ToJsonString $newItem
                    $statusCode = 201
                }
                else {
                    $statusCode = 404
                    $responseData = '{"error":"Card not found"}'
                }
            }

            # Route: PUT /api/checklist/:id
            elseif ($url -match '^/api/checklist/(\d+)$' -and $request.HttpMethod -eq "PUT") {
                $itemId = [int]$url.Split('/')[3]
                
                # Find the card containing this item
                foreach ($cardId in $global:KanbanData.cards.Keys) {
                    $card = $global:KanbanData.cards[$cardId]
                    foreach ($item in $card.checklist) {
                        if ($item.id -eq $itemId) {
                            if ($body.text -ne $null) { $item.text = $body.text }
                            if ($body.completed -ne $null) { $item.completed = $body.completed }
                            break
                        }
                    }
                }
                
                Save-Data
                $responseData = '{"success":true}'
            }

            # Route: DELETE /api/checklist/:id
            elseif ($url -match '^/api/checklist/(\d+)$' -and $request.HttpMethod -eq "DELETE") {
                $itemId = [int]$url.Split('/')[3]
                
                # Find and remove the item
                foreach ($cardId in $global:KanbanData.cards.Keys) {
                    $card = $global:KanbanData.cards[$cardId]
                    $newChecklist = @()
                    $found = $false
                    foreach ($item in $card.checklist) {
                        if ($item.id -eq $itemId) {
                            $found = $true
                        }
                        else {
                            $newChecklist += $item
                        }
                    }
                    if ($found) {
                        $card.checklist = $newChecklist
                        break
                    }
                }
                
                Save-Data
                $responseData = '{"success":true}'
            }

            # Unknown route
            else {
                $statusCode = 404
                $responseData = '{"error":"Not found"}'
            }

            # Send response
            $response.Headers.Add("Access-Control-Allow-Origin", "*")
            $response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
            $response.Headers.Add("Access-Control-Allow-Headers", "Content-Type")
            $response.Headers.Add("X-Content-Type-Options", "nosniff")
            $response.Headers.Add("X-Frame-Options", "DENY")
            $response.Headers.Add("X-XSS-Protection", "1; mode=block")

            if ($request.HttpMethod -eq "OPTIONS") {
                $response.StatusCode = 200
            }
            else {
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($responseData)
                $response.ContentLength64 = $buffer.Length
                $response.ContentType = $contentType
                $response.StatusCode = $statusCode
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            }
            $response.OutputStream.Close()
        }
        catch {
            $errorMsg = $_.Exception.Message
            $errorMsg = $errorMsg.Replace('"', "'").Replace("`r", "").Replace("`n", "")
            $errorJson = "{`"error`":`"$errorMsg`"}"
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($errorJson)
            $response.ContentLength64 = $buffer.Length
            $response.StatusCode = 500
            $response.ContentType = "application/json"
            try {
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            } catch {}
            $response.OutputStream.Close()
            Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host $_.ScriptStackTrace -ForegroundColor Red
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
    Write-Host "`nServer stopped. Total requests: $requestCount" -ForegroundColor Yellow
}
