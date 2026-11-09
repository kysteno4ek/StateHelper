-- Optional browser UI. No network request or process is started while loading this module.
return function(env)
 local ffi,json,imgui,gui,u8=env.ffi,env.json,env.imgui,env.gui,env.u8
 local root=env.root
 local state={started=false,mode='embedded',installing=false,seq=0,queue={},status={},last_poll=-10,last_write=-10,last_draw=-10,address='',message='',sites={}}
 local kernel=ffi.load('kernel32')
 local user=ffi.load('user32')
 pcall(ffi.cdef,[[
  unsigned long __stdcall GetCurrentProcessId(void);
  unsigned long __stdcall GetWindowThreadProcessId(void*,unsigned long*);
  int __stdcall MoveFileExA(const char*,const char*,unsigned long);
 ]])
 local pid=tonumber(kernel.GetCurrentProcessId())
 local private_files={['control.json']=true,['status.json']=true,['host-error.json']=true,['sites.json']=true}
 local function path(name)
  local base=private_files[name] and env.private_root or root
  return base..'/'..name
 end
 local function read(name)
  local file=io.open(path(name),'rb');if not file then return nil end
  local body=file:read(65537);file:close();if not body or #body>65536 then return nil end
  local ok,value=pcall(json.decode,body);return ok and type(value)=='table' and value or nil
 end
 local function write(name,value)
  local ok,body=pcall(json.encode,value);if not ok or #body>65536 then return false end
  local temporary=path(name)..'.lua.tmp';local file=io.open(temporary,'wb');if not file then return false end
  local written=file:write(body);local closed=file:close()
  if not written or not closed then os.remove(temporary);return false end
  return kernel.MoveFileExA(temporary,path(name),9)~=0
 end
 local function exists(name)local file=io.open(path(name),'rb');if not file then return false end;file:close();return true end
 local function deps()return exists('ready.json') and exists('Microsoft.Web.WebView2.Core.dll') and exists('Microsoft.Web.WebView2.WinForms.dll') and exists('WebView2Loader.dll') end
 local function text(value)local ok,result=pcall(function()return u8:decode(tostring(value or ''))end);return ok and result or '' end
 local preferences=read('preferences.json')
 if preferences and (preferences.browser_mode=='external' or preferences.browser_mode=='embedded') then state.mode=preferences.browser_mode end
 if preferences and (preferences.search_engine=='yandex' or preferences.search_engine=='google') then state.search_engine=preferences.search_engine end
 local function select_search(engine)
  if engine~='yandex' and engine~='google' then return end
  if write('preferences.json',{version=1,search_engine=engine,browser_mode=state.mode}) then state.search_engine=engine;state.message='';state.settings_message='Настройки сохранены.'
  else state.message='Не удалось сохранить выбор. Попробуйте ещё раз.';state.settings_message=state.message end
  state.settings_message_at=os.clock()
 end
 local function valid_url(value)
  if type(value)~='string' then return nil end
  value=value:match('^%s*(.-)%s*$')
  if #value==0 or #value>2048 or value:find('[%z\1-\32\127]') then return nil end
  if not value:find('://',1,true) then
   if value:find(':',1,true) and not value:match('^[^:]+:%d+[/#?]?') then return nil end
   value='https://'..value
  end
  local authority=value:match('^https?://([^/%?#]+)')
  if not authority or authority:find('@',1,true) or authority:find('[\\<>"\']') then return nil end
  return value
 end
 state.sites={{name=u8'Форум Arizona',url='https://forum.arizona-rp.com/',kind='forum'},{name='YouTube',url='https://www.youtube.com/',kind='youtube'}}
 local stored=read('sites.json')
 if stored and stored.version==1 and type(stored.sites)=='table' then
  for _,site in ipairs(stored.sites) do
   if #state.sites>=32 then break end
   if type(site)=='table' and type(site.name)=='string' and #site.name>0 and #site.name<=96 and not site.name:find('[%z\1-\31\127]') and valid_url(site.url) then
    state.sites[#state.sites+1]={name=site.name,url=valid_url(site.url),kind='custom'}
   end
  end
 end
 local function save_sites(sites)
  local custom={}
  for i=3,#sites do custom[#custom+1]={name=sites[i].name,url=sites[i].url} end
  if not write('sites.json',{version=1,sites=custom}) then state.edit_error='Не удалось сохранить сайты. Попробуйте ещё раз.';return false end
  state.sites=sites;return true
 end
 local function launch(args,show)
  if not exists('StateHelperBrowser.exe') then state.message='Файл браузера не найден. Восстановите файлы StateHelper.';return false end
  local handle=env.shell32.ShellExecuteA(nil,'open',path('StateHelperBrowser.exe'),args,root,show or 0)
  if tonumber(ffi.cast('intptr_t',handle))<=32 then state.message='Windows не смогла запустить браузер.';return false end
  return true
 end
 local function command(action,url)
  if #state.queue>=128 then return false end
  state.seq=state.seq+1;state.queue[#state.queue+1]={seq=state.seq,action=action,url=url};state.last_write=-10
  return true
 end
 local function reset_input_queue()
  state.pending_move=nil
  state.input_wait_at=nil
 end
 local function input_failed()
  reset_input_queue()
  for i=#state.queue,1,-1 do
   if state.queue[i].action=='pointer' then table.remove(state.queue,i) end
  end
  if env.input_failed then env.input_failed() end
 end
 local start,close,open_site,submit_address
 start=function(mode)
  mode=mode or state.mode
  if state.pending_mode and not state.started then return end
  if state.started then
   if mode==state.mode then return end
   local url=state.status.url
   close('mode_switch');state.pending_mode=mode;state.pending_url=url;state.reopen_at=os.clock()+1
   state.message='Переключаем режим браузера...';return
  end
  if not deps() then state.message='Сначала скачайте необходимые файлы.';return end
  local parent=ffi.C.GetActiveWindow();local owner=ffi.new('unsigned long[1]')
  if parent==0 or user.GetWindowThreadProcessId(ffi.cast('void*',parent),owner)==0 or tonumber(owner[0])~=pid then state.message='Откройте браузер из активного окна игры.';return end
  state.status_seen=false;state.heartbeat=nil;state.last_status_at=nil
  reset_input_queue();state.input_ack=0;state.parent=tonumber(parent);state.queue={};state.seq=0;state.status={};state.message='Запускаем браузер...'
  os.remove(path('status.json'));os.remove(path('host-error.json'))
  write('control.json',{parent_pid=pid,visible=false,x=20,y=40,w=800,h=500,commands={}})
  local cookie_mode=env.keep_cookies() and 'keep-cookies' or 'private'
  if launch('--host '..state.parent..' '..pid..' '..mode..' '..cookie_mode,mode=='external' and 1 or 0) then state.mode=mode;state.started=true;state.started_at=os.clock();state.last_write=-10 end
 end
 close=function(reason)
  if state.started then write('control.json',{parent_pid=pid,close=true,close_reason=reason or 'user',visible=false,commands={}}) end
  reset_input_queue();state.started=false;state.interactive=false;state.address_edit=false;state.queue={};state.status={};state.pending_mode=nil;state.dismiss_after_seq=nil;state.message='Браузер закрыт.'
  if reason=='unload' and state.forum_texture then pcall(imgui.ReleaseTexture,state.forum_texture);state.forum_texture=nil end
  if reason=='unload' and state.alice_texture then pcall(imgui.ReleaseTexture,state.alice_texture);state.alice_texture=nil end
  if reason=='unload' and state.weather_texture then pcall(imgui.ReleaseTexture,state.weather_texture);state.weather_texture=nil end
  if reason=='unload' and state.youtube_texture then pcall(imgui.ReleaseTexture,state.youtube_texture);state.youtube_texture=nil end
 end
 local function install()
    if state.installing or state.started then return end
  os.remove(path('install.cancel'));os.remove(path('install-status.json'))
   if launch('--install') then state.installing=true;state.install_kind='libraries';state.install_at=os.clock();state.message='Скачиваем необходимые файлы с GitHub StateHelper...';state.install_state=nil end
 end
 local function download_runtime()
  if state.installing then return end
  os.remove(path('install.cancel'));os.remove(path('install-status.json'))
  if launch('--download-runtime') then state.installing=true;state.install_kind='runtime';state.install_at=os.clock();state.message='Скачиваем установщик WebView2 GitHub StateHelper...';state.install_state=nil end
 end
 local function poll(visible)
  local now=os.clock()
  if now-state.last_poll<0.05 then return end
  state.last_poll=now
  if state.pending_mode and now>=state.reopen_at then
   local mode,url=state.pending_mode,state.pending_url;state.pending_mode=nil;state.pending_url=nil
   start(mode);if state.started and url and url~='' then command('navigate',url);if state.mode=='external' then command('focus') end;state.dismiss_after_seq=state.seq end
  end
  if state.installing then
   local result=read('install-status.json')
   if result then
    state.install_state=result
    if result.state=='ready' then
     state.installing=false;state.setup=false;state.message='Файлы скачаны.'
     if state.requested_url then local url=state.requested_url;state.requested_url=nil;open_site(url) end
    elseif result.state=='runtime_ready' then state.installing=false;state.runtime_downloaded=true;state.message='Установщик скачан. Установка Runtime запускается отдельной кнопкой.'
    elseif result.state=='error' then state.installing=false;state.message='Ошибка скачивания: '..tostring(result.code or '')..'. Можно повторить.'
    elseif result.state=='cancelled' then state.installing=false;state.message='Скачивание отменено.' end
   end
   if now-state.install_at>210 then state.installing=false;state.message='Скачивание не завершилось вовремя. Можно повторить.' end
  end
  if not state.started then return end
  local result=read('status.json')
  if result and tonumber(result.parent_pid)==pid then
   if result.code=='closed' then state.started=false;state.interactive=false;state.queue={};state.status=result;state.message='Браузер закрыт.';return end
   state.status_seen=true
   if state.heartbeat~=result.updated_at or state.last_status_at==nil then
    state.heartbeat=result.updated_at;state.last_status_at=now
   end
   state.status=result
   state.interactive=state.mode~='external' and result.interactive==true
   if not state.overlay_rect and state.mode~='external' and tonumber(result.overlay_w) and tonumber(result.overlay_w)>100 and tonumber(result.overlay_h) and tonumber(result.overlay_h)>100 then state.overlay_rect={x=tonumber(result.overlay_x)or 20,y=tonumber(result.overlay_y)or 40,w=tonumber(result.overlay_w),h=tonumber(result.overlay_h)} end
   if result.code=='runtime_missing' then state.setup=true end
   if state.dismiss_after_seq and result.ready and (state.mode~='external' or result.window_visible~=false) and (tonumber(result.ack) or 0)>=state.dismiss_after_seq and result.code~='command_error' and result.code~='blocked_url' and result.code~='control_error' then
    state.dismiss_after_seq=nil
    if type(env.hide_main)=='function' then env.hide_main() end
   end
   local ack=tonumber(result.ack) or 0
   local advanced=ack>state.input_ack
   if state.input_wait_at and advanced then state.input_wait_at=now end
   state.input_ack=ack
   while #state.queue>0 and state.queue[1].seq<=ack do table.remove(state.queue,1) end
   local has_input=false
   for _,entry in ipairs(state.queue) do if entry.action=='pointer' then has_input=true;break end end
   if state.input_wait_at and advanced and result.code=='input_error' then input_failed()
   elseif not has_input then state.input_wait_at=nil end
  end
  local failure=read('host-error.json')
  if failure then state.message='Браузер не запущен: '..tostring(failure.code or 'ошибка');state.started=false;if failure.code=='dependencies_invalid' then state.setup=true end;return end
  if not state.status_seen and now-state.started_at>60 then
   if state.mode~='external' then close('startup_timeout');state.message='Браузер не ответил. Попробуйте открыть его снова.';return end
   state.status.code='connection_wait'
  end
  if state.status_seen and now-(state.last_status_at or now)>30 then
   if state.mode~='external' then close('stale_status');state.message='Браузер перестал отвечать. Можно открыть его снова.';return end
   state.status.code='connection_wait'
  end
  if state.input_wait_at and now-state.input_wait_at>=4 then input_failed() end
  local context=type(env.game_context)=='function' and env.game_context() or {blocked=false,width=1280,height=800}
  if context.input_blocked then
   state.address_edit=false
   if state.interactive and not state.input_suspended then command('game_input') end
   state.input_suspended=true
  else state.input_suspended=false end
  local show=state.mode~='external' and not context.blocked
  local width,height=context.width or 1280,context.height or 800
  local rect=state.overlay_rect or {x=math.max(8,width-816),y=40,w=math.min(800,width-24),h=math.min(500,height-64)}
  if show and context.chat_mouse then
   local x,y,down=context.mouse_x or 0,context.mouse_y or 0,context.mouse_down==true
   if down and not state.pointer_down then
    local lx,ly=x-rect.x,y-rect.y
    if lx>=0 and lx<rect.w and ly>=0 and ly<rect.h then
     if ly<32 and lx>=rect.w-35 then close('close_button');return
     elseif ly>=32 and ly<78 then
      if lx>=8 and lx<42 and state.status.can_back then state.address_edit=false;command('back')
      elseif lx>=48 and lx<82 and state.status.can_forward then state.address_edit=false;command('forward')
      elseif lx>=88 and lx<122 then state.address_edit=false;command('reload')
      elseif lx>=rect.w-92 then submit_address(state.address_edit and state.address_text or state.status.url or '')
      elseif lx>=130 and lx<rect.w-100 then
       state.address_edit=true;state.address_focus=true;state.address_text=state.status.url or ''
       if type(env.begin_address_edit)=='function' then env.begin_address_edit() end
      end
     elseif ly<32 then state.pointer_drag={x=x,y=y,rx=rect.x,ry=rect.y,w=rect.w,h=rect.h,resize=false}
     elseif ly>=rect.h-12 then state.pointer_drag={x=x,y=y,rx=rect.x,ry=rect.y,w=rect.w,h=rect.h,resize=true} end
    end
   end
   local d=state.pointer_drag
   if down and d then
    if d.resize then rect.w=math.max(480,math.min(width-d.rx,d.w+x-d.x));rect.h=math.max(280,math.min(height-d.ry,d.h+y-d.y))
    else rect.x=math.max(0,math.min(width-rect.w,d.rx+x-d.x));rect.y=math.max(0,math.min(height-rect.h,d.ry+y-d.y)) end
    state.overlay_rect=rect
   end
   if not down then state.pointer_drag=nil end
   state.pointer_down=down
  else state.pointer_drag=nil;state.pointer_down=false end
  if now-state.last_write>=0.05 then
   if show and context.chat_mouse and state.pending_move and #state.queue==0 then
    command('pointer',state.pending_move)
    state.input_wait_at=state.input_wait_at or now
   end
   state.pending_move=nil
   write('control.json',{parent_pid=pid,visible=not not show,chat_mouse=context.chat_mouse==true,mouse_x=context.mouse_x or 0,mouse_y=context.mouse_y or 0,mouse_down=context.mouse_down==true,x=rect.x,y=rect.y,w=rect.w,h=rect.h,commands=state.queue})
   state.last_write=now
  end
 end
 open_site=function(url)
  url=valid_url(url)
  if not url then state.message='Укажите корректный адрес сайта.';return end
  if not deps() then state.requested_url=url;state.setup=true;return end
  start(state.mode)
  if state.pending_mode then state.pending_url=url
  elseif state.started then command('navigate',url);if state.mode=='external' then command('focus') end;state.dismiss_after_seq=state.seq end
 end
 submit_address=function(value)
  value=tostring(value or ''):match('^%s*(.-)%s*$')
  if value=='' then return end
  local url
  if value:find('://',1,true) or (not value:find('%s') and (value:find('%.') or value:match('^localhost[:/]?'))) then url=valid_url(value)
  else
   local encoded=value:gsub('[^A-Za-z0-9%-_%.~]',function(c)return string.format('%%%02X',string.byte(c))end)
   url=(state.search_engine=='google' and 'https://www.google.com/search?q=' or 'https://yandex.ru/search/?text=')..encoded
  end
  if not url then state.message='Укажите корректный адрес сайта.';return end
  state.address_edit=false;open_site(url)
 end
 local labels={connection_wait='Ожидаем связь с окном браузера.',ready='',loading='Открываем сайт...',navigation_error='Не удалось загрузить страницу.',runtime_missing='Для браузера требуется WebView2 Runtime.',initialization_error='Не удалось открыть браузер.',blocked_url='Этот адрес не поддерживается.',download_blocked='Загрузка файлов с сайтов пока недоступна.',process_failed='Окно браузера можно открыть повторно.',command_error='Не удалось открыть сайт.',control_error='Нет связи с окном браузера.'}
 local function submit_site()
  local editor=state.editor
  local name=editor.name:match('^%s*(.-)%s*$')
  local url=valid_url(editor.url)
  if #name==0 or #name>96 or name:find('[%z\1-\31\127]') then state.edit_error='Введите короткое название сайта.';return end
  if not url then state.edit_error='Введите адрес сайта: например, https://example.com';return end
  if not editor.index and #state.sites>=32 then state.edit_error='Можно сохранить до 30 своих сайтов.';return end
  local sites={};for i,site in ipairs(state.sites) do sites[i]=site end
  sites[editor.index or (#sites+1)]={name=name,url=url,kind='custom'}
  if save_sites(sites) then state.editor=nil;state.edit_error=nil;state.message='' end
 end
 local function delete_site()
  local index=state.editor and state.editor.index
  if not index or index<=2 then return end
  local sites={};for i,site in ipairs(state.sites) do if i~=index then sites[#sites+1]=site end end
  if save_sites(sites) then state.editor=nil;state.edit_error=nil;state.message='' end
 end
 local function shorten(label,width)
  if imgui.CalcTextSize(label).x<=width then return label end
  while #label>0 and imgui.CalcTextSize(label..'...').x>width do
   label=label:match('^(.*)[%z\1-\127\194-\244][\128-\191]*$') or ''
  end
  return label..'...'
 end
 local function tile(site,index,x,y,font,bold,add)
  local w,h=148,96
  imgui.SetCursorPos(imgui.ImVec2(x,y));local pos=imgui.GetCursorScreenPos()
  local clicked=imgui.InvisibleButton('##BrowserTile'..tostring(index),imgui.ImVec2(w,h))
  local hovered=imgui.IsItemHovered()
  local edit=not add and index>2 and imgui.IsItemClicked(1)
  local dl=imgui.GetWindowDrawList()
  local function point(a,b)return imgui.ImVec2(pos.x+a,pos.y+b)end
  local function color(r,g,b,a)return imgui.GetColorU32Vec4(imgui.ImVec4(r,g,b,a or 1))end
  local blue=color(0.29,0.40,1)
  dl:AddRectFilled(point(0,0),point(w,h),add and blue or color(1,1,1),12,15)
  if hovered then dl:AddRect(point(1,1),point(w-1,h-1),add and color(0.70,0.76,1) or blue,11,15,2) end
  if add then
   dl:AddLine(point(w/2-11,34),point(w/2+11,34),color(1,1,1),3)
   dl:AddLine(point(w/2,23),point(w/2,45),color(1,1,1),3)
  elseif site.kind=='forum' then
   if state.forum_texture==nil and doesFileExist(env.images_root .. '/forum-arizona-hq.png') then
    local ok,texture=pcall(function()return imgui.CreateTextureFromFile(env.images_root .. '/forum-arizona-hq.png')end)
    state.forum_texture=ok and texture or false
   end
   if state.forum_texture then
    imgui.SetCursorPos(imgui.ImVec2(x+w/2-28,y+7))
    imgui.Image(state.forum_texture,imgui.ImVec2(56,56),imgui.ImVec2(0,0),imgui.ImVec2(1,1))
   else
    dl:AddCircleFilled(point(w/2,35),20,color(1,0.35,0.27),40)
    imgui.PushFont(bold[1]);local size=imgui.CalcTextSize('A')
    imgui.SetCursorPos(imgui.ImVec2(x+(w-size.x)/2,y+35-size.y/2));imgui.TextColored(imgui.ImVec4(1,1,1,1),'A');imgui.PopFont()
   end
  elseif site.kind=='youtube' then
   if state.youtube_texture==nil and doesFileExist(env.images_root .. '/youtube-hq.png') then
    local ok,texture=pcall(function()return imgui.CreateTextureFromFile(env.images_root .. '/youtube-hq.png')end)
    state.youtube_texture=ok and texture or false
   end
   if state.youtube_texture then
    imgui.SetCursorPos(imgui.ImVec2(x+w/2-28,y+7));imgui.Image(state.youtube_texture,imgui.ImVec2(56,56),imgui.ImVec2(0,0),imgui.ImVec2(1,1))
   else
   dl:AddRectFilled(point(w/2-21,21),point(w/2+21,49),color(1,0,0),8,15)
   dl:AddTriangleFilled(point(w/2-4,27),point(w/2-4,43),point(w/2+9,35),color(1,1,1))
   end
  else
   local palettes={{0.32,0.43,0.96},{0.55,0.35,0.88},{0.04,0.63,0.53},{0.91,0.46,0.14}}
   local shade=(site.kind=='forum' or site.kind=='yandex') and {1,0.35,0.27} or site.kind=='google' and {0.26,0.52,0.96} or palettes[(index-3)%#palettes+1]
   dl:AddCircleFilled(point(w/2,35),20,color(shade[1],shade[2],shade[3]),40)
   local letter=site.kind=='forum' and 'A' or (site.name:match('^[%z\1-\127\194-\244][\128-\191]*') or '?')
   imgui.PushFont(bold[1]);local size=imgui.CalcTextSize(letter)
   imgui.SetCursorPos(imgui.ImVec2(x+(w-size.x)/2,y+35-size.y/2));imgui.TextColored(imgui.ImVec4(1,1,1,1),letter);imgui.PopFont()
  end
  imgui.PushFont(font[3])
  local label=shorten(add and u8'Добавить сайт' or site.name,w-16)
  local size=imgui.CalcTextSize(label)
  imgui.SetCursorPos(imgui.ImVec2(x+(w-size.x)/2,y+68))
  imgui.TextColored(add and imgui.ImVec4(1,1,1,1) or imgui.ImVec4(0.12,0.12,0.14,1),label)
  imgui.PopFont()
  if clicked then
   if add then state.editor={name='',url=''};state.edit_error=nil
   elseif site.search_engine then select_search(site.search_engine)
   else open_site(site.url) end
  elseif edit then state.editor={index=index,name=site.name,url=site.url};state.edit_error=nil end
 end
 local function draw_setup(font,bold)
  local runtime=state.status.code=='runtime_missing' or state.install_kind=='runtime'
  gui.Text(24,22,runtime and 'Компонент браузера' or 'Первое открытие браузера',bold[1])
  gui.Text(24,65,runtime and 'На компьютере не найден Microsoft Edge WebView2 Runtime.' or 'Для открытия сайтов нужны библиотеки Microsoft — около 9,4 МБ.',font[3])
  gui.Text(24,95,'Файлы сохраняются в State Helper/Browser. Загрузка — только по кнопке.',font[3])
  if state.installing then
   local progress=state.install_state
   local percent=progress and math.min(100,math.floor((tonumber(progress.received) or 0)/math.max(1,tonumber(progress.total) or 1)*100)) or 0
   gui.Text(24,150,'Загрузка: '..percent..'%. Проверяем целостность файлов.',font[3])
   if gui.Button(u8'Отменить загрузку',{24,195},{220,34}) then local file=io.open(path('install.cancel'),'wb');if file then file:write('cancel');file:close() end end
  elseif runtime then
   if not state.runtime_downloaded and gui.Button(u8'Скачать WebView2 Runtime',{24,150},{300,38}) then download_runtime() end
   if state.runtime_downloaded and gui.Button(u8'Установить WebView2 Runtime',{24,150},{320,38}) then close('runtime_install');launch('--run-runtime');state.setup=false;state.install_kind=nil;state.message='После установки нажмите на нужный сайт.' end
  elseif gui.Button(u8'Скачать необходимые файлы',{24,150},{325,38}) then install() end
  if not state.installing and gui.Button(u8'Вернуться к сайтам',{24,240},{220,30}) then state.setup=false;state.install_kind=nil end
  gui.Text(24,307,state.message,font[2])
 end
 local function draw_editor(font,bold)
  local editor=state.editor
  gui.Text(24,20,editor.index and 'Изменить сайт' or 'Добавить сайт',bold[1])
  gui.Text(24,74,'Название',font[3])
  editor.name=gui.InputText({160,76},590,editor.name,u8'Название сайта##BrowserSite',128,u8'Например: мой сайт')
  gui.Text(24,126,'Адрес сайта',font[3])
  local enter;editor.url,enter=gui.InputText({160,128},590,editor.url,u8'Адрес сайта##BrowserSite',2048,u8'https://example.com')
  if gui.Button(u8'Сохранить сайт',{24,190},{190,36}) or enter then submit_site() end
  if gui.Button(u8'Отмена##BrowserSite',{226,190},{150,36}) then state.editor=nil;state.edit_error=nil end
  if editor.index and gui.Button(u8'Удалить сайт',{576,190},{190,36}) then delete_site() end
  if state.edit_error then gui.Text(24,255,state.edit_error,font[3]) end
 end
 local function draw_yandex_shortcuts(font,bold)
  local dl=imgui.GetWindowDrawList()
  imgui.SetCursorPos(imgui.ImVec2(0,0));local origin=imgui.GetCursorScreenPos()
  local group_offset=(840-(80*2+8))/2-380
  local function position(x,y)return imgui.ImVec2(x+group_offset,y+24)end
  local function point(x,y)return imgui.ImVec2(origin.x+x+group_offset,origin.y+y+24)end
  local function color(r,g,b,a)return imgui.GetColorU32Vec4(imgui.ImVec4(r,g,b,a or 1))end
  imgui.SetCursorPos(position(380,22));local alice=imgui.InvisibleButton('##BrowserAlice',imgui.ImVec2(80,80));local hovered=imgui.IsItemHovered()
  if hovered then dl:AddRectFilled(point(380,22),point(460,102),color(0.16,0.16,0.19),14,15) end
  if state.alice_texture==nil and doesFileExist(env.images_root .. '/alice-ai-transparent.png') then
   local ok,texture=pcall(function()return imgui.CreateTextureFromFile(env.images_root .. '/alice-ai-transparent.png')end)
   state.alice_texture=ok and texture or false
  end
  if state.alice_texture then
   imgui.SetCursorPos(position(396,29));imgui.Image(state.alice_texture,imgui.ImVec2(48,48),imgui.ImVec2(0,0),imgui.ImVec2(1,1))
  else
   dl:AddCircleFilled(point(420,53),23,color(0.53,0.35,0.89),40)
   imgui.PushFont(bold[1]);imgui.SetCursorPos(position(408,44));imgui.TextColored(imgui.ImVec4(1,1,1,1),'AI');imgui.PopFont()
  end
  imgui.PushFont(font[3]);local size=imgui.CalcTextSize(u8'Алиса AI');imgui.SetCursorPos(position(420-size.x/2,81));imgui.TextColored(imgui.ImVec4(0.94,0.94,0.96,1),u8'Алиса AI');imgui.PopFont()
  if alice then open_site('https://alice.yandex.ru/?utm_source=yandex&utm_campaign=home_web&utm_medium=interface') end
  imgui.SetCursorPos(position(468,22));local weather=imgui.InvisibleButton('##BrowserWeather',imgui.ImVec2(80,80));local weather_hover=imgui.IsItemHovered()
  if weather_hover then dl:AddRectFilled(point(468,22),point(548,102),color(0.16,0.16,0.19),14,15) end
  if state.weather_texture==nil and doesFileExist(env.images_root .. '/weather-clouds.png') then
   local ok,texture=pcall(function()return imgui.CreateTextureFromFile(env.images_root .. '/weather-clouds.png')end)
   state.weather_texture=ok and texture or false
  end
  if state.weather_texture then imgui.SetCursorPos(position(480,25));imgui.Image(state.weather_texture,imgui.ImVec2(56,56),imgui.ImVec2(0,0),imgui.ImVec2(1,1)) end
  imgui.PushFont(font[3]);local weather_size=imgui.CalcTextSize(u8'Погода');imgui.SetCursorPos(position(508-weather_size.x/2,81));imgui.TextColored(imgui.ImVec4(0.94,0.94,0.96,1),u8'Погода');imgui.PopFont()
  if weather then open_site('https://yandex.ru/pogoda/14?lat=56.858745&lon=35.917421&utm_campaign=informer&utm_content=main_informer&utm_medium=web&utm_source=home') end
 end
 local function draw_search(font,bold)
  local google=state.search_engine=='google'
  if google then
   imgui.PushFont(bold[2]);local size=imgui.CalcTextSize('Google')
   imgui.SetCursorPos(imgui.ImVec2((840-size.x)/2,52));imgui.TextColored(imgui.ImVec4(0.97,0.97,0.98,1),'Google');imgui.PopFont()
  else draw_yandex_shortcuts(font,bold) end
  local x,y,w,h=google and 76 or 28,144,google and 688 or 784,52
  imgui.SetCursorPos(imgui.ImVec2(x,y));local pos=imgui.GetCursorScreenPos();local dl=imgui.GetWindowDrawList()
  local function point(a,b)return imgui.ImVec2(pos.x+a,pos.y+b)end
  local function color(r,g,b,a)return imgui.GetColorU32Vec4(imgui.ImVec4(r,g,b,a or 1))end
  dl:AddRectFilled(point(0,0),point(w,h),google and color(0.20,0.21,0.24) or color(0.22,0.22,0.22),h/2,15)
  if google then
   dl:AddRect(point(0,0),point(w,h),color(0.30,0.31,0.34),h/2,15,1)
   dl:AddLine(point(19,26),point(33,26),color(0.88,0.89,0.92),2)
   dl:AddLine(point(26,19),point(26,33),color(0.88,0.89,0.92),2)
  else
   dl:AddCircleFilled(point(26,26),21,color(1,0.35,0.27),48)
   imgui.PushFont(bold[3]);local size=imgui.CalcTextSize(u8'Я')
   imgui.SetCursorPos(imgui.ImVec2(x+26-size.x/2,y+26-size.y/2));imgui.TextColored(imgui.ImVec4(1,1,1,1),u8'Я');imgui.PopFont()
  end
  if not state.query_buf then state.query_buf=ffi.new('char[512]') end
  imgui.PushFont(google and (env.search_font or font[3]) or font[3])
  imgui.PushStyleColor(imgui.Col.FrameBg,imgui.ImVec4(0,0,0,0))
  imgui.PushStyleColor(imgui.Col.FrameBgHovered,imgui.ImVec4(0,0,0,0))
  imgui.PushStyleColor(imgui.Col.FrameBgActive,imgui.ImVec4(0,0,0,0))
  imgui.PushStyleColor(imgui.Col.Text,imgui.ImVec4(0.94,0.94,0.96,1))
  imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding,imgui.ImVec2(0,7))
  imgui.PushStyleVarFloat(imgui.StyleVar.FrameBorderSize,0)
  imgui.SetCursorPos(imgui.ImVec2(x+56,y+10));imgui.PushItemWidth(w-190)
  local enter=imgui.InputText('##BrowserHomeSearch',state.query_buf,ffi.sizeof(state.query_buf),imgui.InputTextFlags.EnterReturnsTrue)
  local active=imgui.IsItemActive()
  imgui.PopItemWidth();imgui.PopStyleVar(2);imgui.PopStyleColor(4)
  if state.query_buf[0]==0 and not active then
   local placeholder=google and u8'Поиск в Google' or u8'Найдётся всё';local size=imgui.CalcTextSize(placeholder)
   imgui.SetCursorPos(imgui.ImVec2(x+(w-size.x)/2,y+(h-size.y)/2));imgui.TextColored(imgui.ImVec4(0.60,0.61,0.64,1),placeholder)
  end
  imgui.PopFont()
  imgui.SetCursorPos(imgui.ImVec2(x+w-116,y+7))
  local clicked=imgui.InvisibleButton('##BrowserHomeGo',imgui.ImVec2(108,38));local hovered=imgui.IsItemHovered()
  dl:AddRectFilled(point(w-116,7),point(w-8,45),hovered and color(0.39,0.50,0.98) or color(0.31,0.42,0.88),19,15)
  imgui.PushFont(font[3]);local label=u8'Перейти';local size=imgui.CalcTextSize(label)
  imgui.SetCursorPos(imgui.ImVec2(x+w-109+(76-size.x)/2,y+(h-size.y)/2));imgui.TextColored(imgui.ImVec4(1,1,1,1),label);imgui.PopFont()
  dl:AddLine(point(w-30,26),point(w-19,26),color(1,1,1),1.7)
  dl:AddLine(point(w-24,21),point(w-19,26),color(1,1,1),1.7)
  dl:AddLine(point(w-24,31),point(w-19,26),color(1,1,1),1.7)
  if enter or clicked then
   local query=ffi.string(state.query_buf):match('^%s*(.-)%s*$')
   if query~='' then
    local encoded=query:gsub('[^A-Za-z0-9%-_%.~]',function(char)return string.format('%%%02X',string.byte(char))end)
    open_site((google and 'https://www.google.com/search?q=' or 'https://yandex.ru/search/?text=')..encoded)
   end
  end
 end
 local function select_mode(mode)
  if mode~='embedded' and mode~='external' then return end
  if not write('preferences.json',{version=1,search_engine=state.search_engine,browser_mode=mode}) then state.settings_message='Не удалось сохранить режим.';return end
  if state.started then start(mode) else state.mode=mode end
  state.settings_message='Режим сохранён.';state.settings_message_at=os.clock()
 end
 local function toggle_input()
  if state.started and state.mode~='external' then command('toggle_input') end
 end
 local function draw_settings(cl,font,bold)
  gui.DrawBox({16,110},{586,96},cl.tab,cl.line,7,15)
  gui.Text(26,121,'Поисковая система браузера',bold[1])
  if gui.Button(u8'Яндекс'..(state.search_engine=='yandex' and u8' (выбран)' or ''),{26,160},{220,32}) then select_search('yandex') end
  if gui.Button('Google'..(state.search_engine=='google' and u8' (выбран)' or ''),{258,160},{220,32}) then select_search('google') end
  gui.DrawBox({16,220},{586,132},cl.tab,cl.line,7,15)
  gui.Text(26,231,'Где открывать браузер',bold[1])
  if gui.Button(u8'В игре'..(state.mode~='external' and u8' (выбран)' or ''),{26,266},{220,30}) then select_mode('embedded') end
  if gui.Button(u8'Отдельное окно'..(state.mode=='external' and u8' (выбран)' or ''),{258,266},{220,30}) then select_mode('external') end
  gui.Text(26,311,'Ctrl+B — переключить управление игрой и браузером.',font[3])
  if state.settings_message and os.clock()-(state.settings_message_at or 0)<4 then gui.Text(26,365,state.settings_message,font[3]) end
 end
 local function draw(cl,font,bold_font)
  state.last_draw=os.clock()
  imgui.SetCursorPos(imgui.ImVec2(4,39))
  imgui.BeginChild('##StateHelperBrowser',imgui.ImVec2(840,369),false,imgui.WindowFlags.NoScrollbar+imgui.WindowFlags.NoScrollWithMouse)
  if not state.search_engine then
   local question='Каким поиском вы пользуетесь?'
   imgui.PushFont(bold_font[1]);local size=imgui.CalcTextSize(u8(question));imgui.PopFont()
   gui.Text((840-size.x)/2,68,question,bold_font[1])
   tile({name=u8'Яндекс',kind='yandex',search_engine='yandex'},1,260,138,font,bold_font,false)
   tile({name='Google',kind='google',search_engine='google'},2,424,138,font,bold_font,false)
   if state.message~='' then gui.Text(24,300,state.message,font[3]) end
  elseif state.editor then draw_editor(font,bold_font)
  elseif state.setup or state.installing then draw_setup(font,bold_font)
  else
   draw_search(font,bold_font)
   imgui.SetCursorPos(imgui.ImVec2(12,214));imgui.BeginChild('##BrowserSitesGrid',imgui.ImVec2(816,124),false,0)
   local count=#state.sites
   for i=1,count+1 do
    local row=math.floor((i-1)/5);local columns=math.min(5,count+1-row*5)
    local left=(816-(columns*148+(columns-1)*12))/2
    tile(state.sites[i],i,left+((i-1)%5)*160,8+row*108,font,bold_font,i==count+1)
   end
   imgui.SetCursorPos(imgui.ImVec2(0,8+math.ceil((count+1)/5)*108));imgui.Dummy(imgui.ImVec2(1,1))
   imgui.EndChild()
   if state.status.code and (state.status.code:find('error',1,true) or state.status.code=='connection_wait') then gui.Text(22,334,labels[state.status.code] or state.message,font[2]) end
  end
  imgui.EndChild()
 end
 local function pointer(kind,x,y,delta,down)
  if not state.started or state.mode=='external' then return end
  local payload=json.encode({type=kind,x=x,y=y,delta=delta,down=down})
  if kind=='mouseMoved' then state.pending_move=payload;return end
  if state.pending_move and #state.queue<8 then command('pointer',state.pending_move) end
  state.pending_move=nil
  if not command('pointer',payload) then input_failed();return end
  state.input_wait_at=state.input_wait_at or os.clock()
 end
 return {install=install,submit_address=submit_address,pointer=pointer,draw=draw,draw_settings=draw_settings,poll=poll,close=close,toggle_input=toggle_input,open_site=open_site,select_mode=select_mode,state=state}
end
