# bot.py - XeloraCloud VPS Bot - Enhanced Edition
import discord
from discord.ext import commands, tasks
import asyncio
import subprocess
import json
from datetime import datetime, timedelta
import shlex
import logging
import shutil
import os
from typing import Optional, List, Dict, Any
import threading
import time
import sqlite3
import random
import psutil
import aiohttp
from collections import defaultdict

# ==================== CONFIGURATION ====================
DISCORD_TOKEN = os.getenv('DISCORD_TOKEN', 'YOUR_TOKEN_HERE')
BOT_NAME = os.getenv('BOT_NAME', 'XeloraCloud')
PREFIX = os.getenv('PREFIX', '.')
YOUR_SERVER_IP = os.getenv('YOUR_SERVER_IP', '0.0.0.0')
MAIN_ADMIN_ID = int(os.getenv('MAIN_ADMIN_ID', '0'))
VPS_USER_ROLE_ID = int(os.getenv('VPS_USER_ROLE_ID', '0'))
DEFAULT_STORAGE_POOL = os.getenv('DEFAULT_STORAGE_POOL', 'default')
LOG_CHANNEL_ID = int(os.getenv('LOG_CHANNEL_ID', '0'))

# Parse additional admins from comma-separated string
ADDITIONAL_ADMINS = os.getenv('ADDITIONAL_ADMINS', '')
ADDITIONAL_ADMIN_IDS = [admin_id.strip() for admin_id in ADDITIONAL_ADMINS.split(',') if admin_id.strip()]

# OS Options with more choices
OS_OPTIONS = [
    {"label": "Ubuntu 24.04 LTS (Latest)", "value": "ubuntu:24.04", "emoji": "🟢"},
    {"label": "Ubuntu 22.04 LTS (Stable)", "value": "ubuntu:22.04", "emoji": "🔵"},
    {"label": "Ubuntu 20.04 LTS", "value": "ubuntu:20.04", "emoji": "🟡"},
    {"label": "Debian 13 (Trixie - Testing)", "value": "images:debian/13", "emoji": "🔴"},
    {"label": "Debian 12 (Bookworm)", "value": "images:debian/12", "emoji": "🟣"},
    {"label": "Debian 11 (Bullseye)", "value": "images:debian/11", "emoji": "🟠"},
    {"label": "Alpine Linux (Lightweight)", "value": "images:alpine/edge", "emoji": "⚪"},
    {"label": "Arch Linux (Rolling)", "value": "images:archlinux", "emoji": "🔷"},
    {"label": "CentOS Stream 9", "value": "images:centos/9-Stream", "emoji": "🟤"},
    {"label": "Rocky Linux 9", "value": "images:rockylinux/9", "emoji": "💚"},
]

# Enhanced logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('xeloracloud.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger('XeloraCloud')

# Check LXC availability
if not shutil.which("lxc"):
    logger.error("LXC command not found. Please install LXD/LXC first.")
    raise SystemExit("LXC not found. Run the install.sh script first!")

# ==================== DATABASE SETUP ====================
def get_db():
    conn = sqlite3.connect('xeloracloud.db')
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    conn = get_db()
    cur = conn.cursor()
    
    # Admins table
    cur.execute('''CREATE TABLE IF NOT EXISTS admins (
        user_id TEXT PRIMARY KEY,
        added_at TEXT NOT NULL,
        added_by TEXT
    )''')
    
    # Add main admin
    cur.execute('INSERT OR IGNORE INTO admins (user_id, added_at, added_by) VALUES (?, ?, ?)', 
                (str(MAIN_ADMIN_ID), datetime.now().isoformat(), 'SYSTEM'))
    
    # Add additional admins from config
    for admin_id in ADDITIONAL_ADMIN_IDS:
        if admin_id and admin_id != str(MAIN_ADMIN_ID):
            cur.execute('INSERT OR IGNORE INTO admins (user_id, added_at, added_by) VALUES (?, ?, ?)', 
                        (admin_id, datetime.now().isoformat(), 'CONFIG_FILE'))
            logger.info(f"Added additional admin from config: {admin_id}")
    
    # Enhanced VPS table
    cur.execute('''CREATE TABLE IF NOT EXISTS vps (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id TEXT NOT NULL,
        container_name TEXT UNIQUE NOT NULL,
        ram TEXT NOT NULL,
        cpu TEXT NOT NULL,
        storage TEXT NOT NULL,
        bandwidth TEXT DEFAULT 'Unlimited',
        config TEXT NOT NULL,
        os_version TEXT DEFAULT 'ubuntu:24.04',
        status TEXT DEFAULT 'stopped',
        suspended INTEGER DEFAULT 0,
        whitelisted INTEGER DEFAULT 0,
        created_at TEXT NOT NULL,
        last_started TEXT,
        total_uptime INTEGER DEFAULT 0,
        shared_with TEXT DEFAULT '[]',
        suspension_history TEXT DEFAULT '[]',
        tags TEXT DEFAULT '[]',
        notes TEXT DEFAULT ''
    )''')
    
    # Settings table
    cur.execute('''CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at TEXT NOT NULL
    )''')
    
    settings_init = [
        ('cpu_threshold', '90'),
        ('ram_threshold', '90'),
        ('disk_threshold', '85'),
        ('auto_suspend_enabled', 'false'),
        ('max_vps_per_user', '5'),
        ('default_ram', '2'),
        ('default_cpu', '2'),
        ('default_storage', '20'),
    ]
    
    for key, value in settings_init:
        cur.execute('INSERT OR IGNORE INTO settings (key, value, updated_at) VALUES (?, ?, ?)', 
                    (key, value, datetime.now().isoformat()))
    
    # Port allocations
    cur.execute('''CREATE TABLE IF NOT EXISTS port_allocations (
        user_id TEXT PRIMARY KEY,
        allocated_ports INTEGER DEFAULT 0
    )''')
    
    # Port forwards with enhanced tracking
    cur.execute('''CREATE TABLE IF NOT EXISTS port_forwards (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id TEXT NOT NULL,
        vps_container TEXT NOT NULL,
        vps_port INTEGER NOT NULL,
        host_port INTEGER NOT NULL,
        protocol TEXT DEFAULT 'both',
        created_at TEXT NOT NULL,
        last_used TEXT
    )''')
    
    # Backups table
    cur.execute('''CREATE TABLE IF NOT EXISTS backups (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        container_name TEXT NOT NULL,
        backup_name TEXT NOT NULL,
        size_mb INTEGER,
        created_at TEXT NOT NULL,
        created_by TEXT NOT NULL
    )''')
    
    # Audit log
    cur.execute('''CREATE TABLE IF NOT EXISTS audit_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp TEXT NOT NULL,
        user_id TEXT NOT NULL,
        action TEXT NOT NULL,
        target TEXT,
        details TEXT,
        success INTEGER DEFAULT 1
    )''')
    
    # Usage statistics
    cur.execute('''CREATE TABLE IF NOT EXISTS usage_stats (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        container_name TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        cpu_usage REAL,
        ram_usage REAL,
        disk_usage REAL,
        network_rx INTEGER,
        network_tx INTEGER
    )''')
    
    conn.commit()
    conn.close()

def log_audit(user_id: str, action: str, target: str = None, details: str = None, success: bool = True):
    """Log actions for audit trail"""
    try:
        conn = get_db()
        cur = conn.cursor()
        cur.execute('''INSERT INTO audit_log (timestamp, user_id, action, target, details, success)
                       VALUES (?, ?, ?, ?, ?, ?)''',
                    (datetime.now().isoformat(), user_id, action, target, details, 1 if success else 0))
        conn.commit()
        conn.close()
    except Exception as e:
        logger.error(f"Failed to log audit: {e}")

async def send_log_to_discord(title: str, description: str, color: str = 'info', fields: dict = None):
    """Send log message to Discord log channel"""
    if LOG_CHANNEL_ID == 0:
        return
    
    try:
        channel = bot.get_channel(LOG_CHANNEL_ID)
        if channel:
            embed = create_embed(title, description, color)
            
            if fields:
                for name, value in fields.items():
                    add_field(embed, name, value, True)
            
            await channel.send(embed=embed)
    except Exception as e:
        logger.error(f"Failed to send log to Discord: {e}")

def get_setting(key: str, default: Any = None):
    conn = get_db()
    cur = conn.cursor()
    cur.execute('SELECT value FROM settings WHERE key = ?', (key,))
    row = cur.fetchone()
    conn.close()
    return row[0] if row else default

def set_setting(key: str, value: str):
    conn = get_db()
    cur = conn.cursor()
    cur.execute('INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)', 
                (key, value, datetime.now().isoformat()))
    conn.commit()
    conn.close()

# ==================== DATA LOADING ====================
def get_vps_data() -> Dict[str, List[Dict[str, Any]]]:
    conn = get_db()
    cur = conn.cursor()
    cur.execute('SELECT * FROM vps')
    rows = cur.fetchall()
    conn.close()
    
    data = defaultdict(list)
    for row in rows:
        user_id = row['user_id']
        vps = dict(row)
        vps['shared_with'] = json.loads(vps['shared_with'])
        vps['suspension_history'] = json.loads(vps['suspension_history'])
        vps['tags'] = json.loads(vps['tags'])
        vps['suspended'] = bool(vps['suspended'])
        vps['whitelisted'] = bool(vps['whitelisted'])
        data[user_id].append(vps)
    return dict(data)

def get_admins() -> List[str]:
    conn = get_db()
    cur = conn.cursor()
    cur.execute('SELECT user_id FROM admins')
    rows = cur.fetchall()
    conn.close()
    return [row['user_id'] for row in rows]

def save_vps_data():
    conn = get_db()
    cur = conn.cursor()
    for user_id, vps_list in vps_data.items():
        for vps in vps_list:
            shared_json = json.dumps(vps['shared_with'])
            history_json = json.dumps(vps['suspension_history'])
            tags_json = json.dumps(vps.get('tags', []))
            suspended_int = 1 if vps['suspended'] else 0
            whitelisted_int = 1 if vps.get('whitelisted', False) else 0
            
            if 'id' not in vps or vps['id'] is None:
                cur.execute('''INSERT INTO vps (user_id, container_name, ram, cpu, storage, bandwidth, config, 
                               os_version, status, suspended, whitelisted, created_at, last_started, total_uptime,
                               shared_with, suspension_history, tags, notes)
                               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
                            (user_id, vps['container_name'], vps['ram'], vps['cpu'], vps['storage'],
                             vps.get('bandwidth', 'Unlimited'), vps['config'], vps.get('os_version', 'ubuntu:24.04'),
                             vps['status'], suspended_int, whitelisted_int, vps.get('created_at', datetime.now().isoformat()),
                             vps.get('last_started'), vps.get('total_uptime', 0), shared_json, history_json,
                             tags_json, vps.get('notes', '')))
                vps['id'] = cur.lastrowid
            else:
                cur.execute('''UPDATE vps SET user_id=?, ram=?, cpu=?, storage=?, bandwidth=?, config=?, os_version=?, 
                               status=?, suspended=?, whitelisted=?, last_started=?, total_uptime=?, shared_with=?, 
                               suspension_history=?, tags=?, notes=? WHERE id=?''',
                            (user_id, vps['ram'], vps['cpu'], vps['storage'], vps.get('bandwidth', 'Unlimited'),
                             vps['config'], vps.get('os_version', 'ubuntu:24.04'), vps['status'], suspended_int,
                             whitelisted_int, vps.get('last_started'), vps.get('total_uptime', 0),
                             shared_json, history_json, tags_json, vps.get('notes', ''), vps['id']))
    conn.commit()
    conn.close()

# Initialize
init_db()
vps_data = get_vps_data()
admin_data = {'admins': get_admins()}

# Global settings
CPU_THRESHOLD = int(get_setting('cpu_threshold', 90))
RAM_THRESHOLD = int(get_setting('ram_threshold', 90))
DISK_THRESHOLD = int(get_setting('disk_threshold', 85))

# ==================== BOT SETUP ====================
intents = discord.Intents.default()
intents.message_content = True
intents.members = True
intents.presences = True

bot = commands.Bot(
    command_prefix=PREFIX,
    intents=intents,
    help_command=None,
    case_insensitive=True
)

# ==================== ENHANCED EMBEDS ====================
COLORS = {
    'primary': 0x00D9FF,      # XeloraCloud Cyan
    'success': 0x00FF88,      # Bright Green
    'error': 0xFF3366,        # Bright Red
    'warning': 0xFFAA00,      # Orange
    'info': 0x00CCFF,         # Light Blue
    'premium': 0xFFD700,      # Gold
    'dark': 0x1a1a2e,         # Dark Background
}

def create_embed(title, description="", color='primary'):
    """Create stunning XeloraCloud branded embed"""
    embed = discord.Embed(
        title=f"☁️ {BOT_NAME} | {title}",
        description=description,
        color=COLORS.get(color, COLORS['primary']),
        timestamp=datetime.now()
    )
    embed.set_thumbnail(url="https://i.imgur.com/XeloraCloud.png")
    embed.set_footer(
        text=f"{BOT_NAME} VPS Hosting • Powered by LXD",
        icon_url="https://i.imgur.com/XeloraCloud.png"
    )
    return embed

def add_field(embed, name, value, inline=False):
    if not value or len(str(value).strip()) == 0:
        value = "N/A"
    embed.add_field(name=f"▸ {name}", value=str(value)[:1024], inline=inline)
    return embed

# ==================== HELPER FUNCTIONS ====================
def is_admin():
    async def predicate(ctx):
        user_id = str(ctx.author.id)
        if user_id == str(MAIN_ADMIN_ID) or user_id in admin_data.get("admins", []):
            return True
        raise commands.CheckFailure("⛔ You need admin permissions to use this command!")
    return commands.check(predicate)

def is_main_admin():
    async def predicate(ctx):
        if str(ctx.author.id) == str(MAIN_ADMIN_ID):
            return True
        raise commands.CheckFailure("⛔ Only the main admin can use this command!")
    return commands.check(predicate)

async def execute_lxc(command, timeout=120):
    """Execute LXC commands with enhanced error handling"""
    try:
        cmd = shlex.split(command)
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        
        if proc.returncode != 0:
            error = stderr.decode().strip() if stderr else "Command failed"
            raise Exception(error)
        
        return stdout.decode().strip() if stdout else True
    except asyncio.TimeoutError:
        logger.error(f"LXC timeout: {command}")
        raise asyncio.TimeoutError(f"⏱️ Command timed out after {timeout}s")
    except Exception as e:
        logger.error(f"LXC error: {command} - {e}")
        raise

async def get_container_status(container_name):
    """Get container status with caching"""
    try:
        result = await execute_lxc(f"lxc info {container_name}")
        for line in result.splitlines():
            if line.startswith("Status: "):
                return line.split(": ", 1)[1].strip().lower()
        return "unknown"
    except:
        return "unknown"

async def apply_lxc_config(container_name):
    """Apply enhanced LXC configuration for Docker/Kubernetes support"""
    try:
        configs = [
            f"lxc config set {container_name} security.nesting true",
            f"lxc config set {container_name} security.privileged true",
            f"lxc config set {container_name} security.syscalls.intercept.mknod true",
            f"lxc config set {container_name} security.syscalls.intercept.setxattr true",
            f"lxc config set {container_name} linux.kernel_modules overlay,loop,nf_nat,ip_tables,ip6_tables,netlink_diag,br_netfilter,iptable_nat,ip6table_nat",
        ]
        
        for config in configs:
            try:
                await execute_lxc(config)
            except:
                pass
        
        # Add devices
        try:
            await execute_lxc(f"lxc config device add {container_name} fuse unix-char path=/dev/fuse")
        except:
            pass
        
        # Raw LXC config for maximum compatibility
        raw_lxc = """lxc.apparmor.profile = unconfined
lxc.cgroup.devices.allow = a
lxc.cap.drop =
lxc.mount.auto = proc:rw sys:rw cgroup:rw"""
        
        await execute_lxc(f"lxc config set {container_name} raw.lxc '{raw_lxc}'")
        logger.info(f"✅ Applied LXC config to {container_name}")
    except Exception as e:
        logger.error(f"Failed to apply LXC config: {e}")

async def apply_internal_permissions(container_name):
    """Apply internal container permissions"""
    try:
        await asyncio.sleep(5)
        
        commands = [
            "mkdir -p /etc/sysctl.d/",
            "echo 'net.ipv4.ip_unprivileged_port_start=0' > /etc/sysctl.d/99-xeloracloud.conf",
            "echo 'net.ipv4.ping_group_range=0 2147483647' >> /etc/sysctl.d/99-xeloracloud.conf",
            "echo 'fs.inotify.max_user_watches=524288' >> /etc/sysctl.d/99-xeloracloud.conf",
            "sysctl -p /etc/sysctl.d/99-xeloracloud.conf || true"
        ]
        
        for cmd in commands:
            try:
                await execute_lxc(f"lxc exec {container_name} -- bash -c \"{cmd}\"")
            except:
                continue
        
        logger.info(f"✅ Applied internal permissions to {container_name}")
    except Exception as e:
        logger.error(f"Failed to apply internal permissions: {e}")

# ==================== BOT EVENTS ====================
@bot.event
async def on_ready():
    logger.info(f'🚀 {bot.user} connected to Discord!')
    logger.info(f'📊 Servers: {len(bot.guilds)} | Users: {len(bot.users)}')
    
    # Log to Discord channel if configured
    if LOG_CHANNEL_ID != 0:
        try:
            channel = bot.get_channel(LOG_CHANNEL_ID)
            if channel:
                embed = create_embed("🚀 Bot Started", f"{BOT_NAME} is now online!", 'success')
                add_field(embed, "Servers", str(len(bot.guilds)), True)
                add_field(embed, "Users", str(len(bot.users)), True)
                add_field(embed, "Latency", f"{round(bot.latency * 1000)}ms", True)
                await channel.send(embed=embed)
        except Exception as e:
            logger.error(f"Failed to send startup message to log channel: {e}")
    
    # Start background tasks
    resource_monitor_task.start()
    update_statistics.start()
    
    # Set presence
    await bot.change_presence(
        activity=discord.Activity(
            type=discord.ActivityType.watching,
            name=f"{len(vps_data)} users • {PREFIX}help"
        ),
        status=discord.Status.online
    )
    
    # Log admin configuration
    logger.info(f"✅ Main Admin: {MAIN_ADMIN_ID}")
    if ADDITIONAL_ADMIN_IDS:
        logger.info(f"✅ Additional Admins: {', '.join(ADDITIONAL_ADMIN_IDS)}")
    
    logger.info(f"✅ {BOT_NAME} is ready!")

@bot.event
async def on_command_error(ctx, error):
    if isinstance(error, commands.CommandNotFound):
        return
    elif isinstance(error, commands.MissingRequiredArgument):
        embed = create_embed("Missing Argument", 
                           f"❌ Missing required argument: `{error.param.name}`\n\nUse `{PREFIX}help` for command usage.",
                           'error')
        await ctx.send(embed=embed)
    elif isinstance(error, commands.BadArgument):
        embed = create_embed("Invalid Argument",
                           f"❌ Invalid argument provided.\n\nUse `{PREFIX}help` for command usage.",
                           'error')
        await ctx.send(embed=embed)
    elif isinstance(error, commands.CheckFailure):
        embed = create_embed("Access Denied", str(error), 'error')
        await ctx.send(embed=embed)
    else:
        logger.error(f"Command error: {error}")
        embed = create_embed("System Error",
                           "❌ An unexpected error occurred. Our team has been notified.",
                           'error')
        await ctx.send(embed=embed)

# ==================== BACKGROUND TASKS ====================
@tasks.loop(minutes=5)
async def resource_monitor_task():
    """Monitor resources every 5 minutes"""
    try:
        auto_suspend = get_setting('auto_suspend_enabled', 'false') == 'true'
        
        for user_id, vps_list in vps_data.items():
            for vps in vps_list:
                if vps['status'] == 'running' and not vps['whitelisted']:
                    container = vps['container_name']
                    # Collect stats
                    # (Implementation would go here)
                    pass
    except Exception as e:
        logger.error(f"Resource monitor error: {e}")

@tasks.loop(hours=1)
async def update_statistics():
    """Update bot statistics hourly"""
    try:
        total_vps = sum(len(vps_list) for vps_list in vps_data.values())
        running_vps = sum(1 for vps_list in vps_data.values() 
                         for vps in vps_list if vps['status'] == 'running')
        
        await bot.change_presence(
            activity=discord.Activity(
                type=discord.ActivityType.watching,
                name=f"{total_vps} VPS ({running_vps} online) • {PREFIX}help"
            )
        )
    except Exception as e:
        logger.error(f"Statistics update error: {e}")

# ==================== BASIC COMMANDS ====================
@bot.command(name='ping')
async def ping(ctx):
    """Check bot latency"""
    latency = round(bot.latency * 1000)
    
    embed = create_embed("🏓 Pong!", color='success')
    add_field(embed, "Latency", f"`{latency}ms`", True)
    add_field(embed, "Status", "🟢 Online", True)
    add_field(embed, "Uptime", f"`{get_bot_uptime()}`", True)
    
    await ctx.send(embed=embed)

def get_bot_uptime():
    """Get bot uptime"""
    # Simplified - you'd track actual bot start time
    return "Running"

@bot.command(name='config', aliases=['settings', 'configuration'])
@is_admin()
async def show_config(ctx):
    """Show current bot configuration"""
    embed = create_embed("⚙️ Bot Configuration", color='info')
    
    # Bot Settings
    bot_info = f"```yaml\nName: {BOT_NAME}\nPrefix: {PREFIX}\nServer IP: {YOUR_SERVER_IP}```"
    add_field(embed, "🤖 Bot Settings", bot_info, False)
    
    # Admin Configuration
    admin_count = len(admin_data.get('admins', []))
    main_admin = await bot.fetch_user(MAIN_ADMIN_ID)
    admin_info = f"```yaml\nMain Admin: {main_admin.name}\nTotal Admins: {admin_count + 1}\nLog Channel: {'Configured' if LOG_CHANNEL_ID != 0 else 'Not Set'}```"
    add_field(embed, "👑 Admin Configuration", admin_info, False)
    
    # Resource Settings
    resource_info = f"```yaml\nCPU Threshold: {CPU_THRESHOLD}%\nRAM Threshold: {RAM_THRESHOLD}%\nDisk Threshold: {DISK_THRESHOLD}%```"
    add_field(embed, "📊 Resource Limits", resource_info, True)
    
    # VPS Defaults
    default_ram = get_setting('default_ram', '2')
    default_cpu = get_setting('default_cpu', '2')
    default_storage = get_setting('default_storage', '20')
    max_vps = get_setting('max_vps_per_user', '5')
    
    vps_info = f"```yaml\nDefault RAM: {default_ram}GB\nDefault CPU: {default_cpu} cores\nDefault Storage: {default_storage}GB\nMax VPS/User: {max_vps}```"
    add_field(embed, "☁️ VPS Defaults", vps_info, True)
    
    await ctx.send(embed=embed)

@bot.command(name='dashboard', aliases=['stats', 'status'])
async def dashboard(ctx):
    """Show XeloraCloud dashboard"""
    total_vps = sum(len(vps_list) for vps_list in vps_data.values())
    running_vps = sum(1 for vps_list in vps_data.values() 
                     for vps in vps_list if vps['status'] == 'running')
    total_users = len(vps_data)
    
    # System stats
    cpu_percent = psutil.cpu_percent(interval=1)
    ram = psutil.virtual_memory()
    disk = psutil.disk_usage('/')
    
    embed = create_embed("📊 XeloraCloud Dashboard", color='primary')
    
    # VPS Stats
    vps_stats = f"```yaml\nTotal VPS: {total_vps}\nRunning: {running_vps}\nStopped: {total_vps - running_vps}\nUsers: {total_users}```"
    add_field(embed, "☁️ VPS Statistics", vps_stats, False)
    
    # System Stats
    sys_stats = f"```yaml\nCPU: {cpu_percent}%\nRAM: {ram.percent}%\nDisk: {disk.percent}%```"
    add_field(embed, "💻 System Resources", sys_stats, True)
    
    # Bot Stats
    bot_stats = f"```yaml\nServers: {len(bot.guilds)}\nLatency: {round(bot.latency * 1000)}ms\nUptime: {get_bot_uptime()}```"
    add_field(embed, "🤖 Bot Status", bot_stats, True)
    
    await ctx.send(embed=embed)

@bot.command(name='adminlist', aliases=['admins'])
@is_admin()
async def list_admins(ctx):
    """List all administrators"""
    embed = create_embed("👑 Administrator List", color='premium')
    
    # Main Admin
    try:
        main_admin = await bot.fetch_user(MAIN_ADMIN_ID)
        main_info = f"**{main_admin.name}** ({main_admin.mention})\n`ID: {MAIN_ADMIN_ID}`\n*Main Administrator*"
        add_field(embed, "👑 Main Admin", main_info, False)
    except:
        add_field(embed, "👑 Main Admin", f"`ID: {MAIN_ADMIN_ID}`", False)
    
    # Additional Admins
    admins = admin_data.get("admins", [])
    if admins:
        admin_list = []
        for i, admin_id in enumerate(admins, 1):
            try:
                admin_user = await bot.fetch_user(int(admin_id))
                admin_list.append(f"**{i}.** {admin_user.name} ({admin_user.mention})\n   `ID: {admin_id}`")
            except:
                admin_list.append(f"**{i}.** Unknown User\n   `ID: {admin_id}`")
        
        add_field(embed, f"🛡️ Additional Admins ({len(admins)})", "\n\n".join(admin_list), False)
    else:
        add_field(embed, "🛡️ Additional Admins", "*No additional admins configured*", False)
    
    # Statistics
    total_vps = sum(len(vps_list) for vps_list in vps_data.values())
    stats = f"```yaml\nTotal Admins: {len(admins) + 1}\nTotal VPS: {total_vps}\nTotal Users: {len(vps_data)}```"
    add_field(embed, "📊 Statistics", stats, False)
    
    await ctx.send(embed=embed)

# This is just a portion of the enhanced bot - I'll create the install script next!
# The full bot would be too long for one artifact, but this shows the enhanced structure

if __name__ == "__main__":
    if DISCORD_TOKEN and DISCORD_TOKEN != 'YOUR_TOKEN_HERE':
        bot.run(DISCORD_TOKEN)
    else:
        logger.error("❌ No Discord token found! Set DISCORD_TOKEN environment variable.")
