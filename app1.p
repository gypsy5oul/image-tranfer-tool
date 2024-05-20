from flask import Flask, request, render_template, jsonify, send_file, session, redirect, url_for, flash
from flask_socketio import SocketIO, emit
from flask_login import LoginManager, UserMixin, login_user, logout_user, login_required, current_user
import psycopg2
import docker
import boto3
import base64
from datetime import datetime, timedelta
import logging
import os
import subprocess
from concurrent.futures import ThreadPoolExecutor
from logging.handlers import TimedRotatingFileHandler
from werkzeug.security import generate_password_hash, check_password_hash
from cryptography.fernet import Fernet
from apscheduler.schedulers.background import BackgroundScheduler
from flask_wtf import FlaskForm
from wtforms import StringField, PasswordField, SubmitField
from wtforms.validators import DataRequired

# Create logs directory if it doesn't exist
os.makedirs('logs', exist_ok=True)
os.makedirs('image_logs', exist_ok=True)
# Setup dynamic logging levels
log_level = os.getenv('LOG_LEVEL', 'INFO').upper()
logging.basicConfig(level=getattr(logging, log_level))

logger = logging.getLogger(__name__)
handler = TimedRotatingFileHandler('logs/app.log', when='midnight', backupCount=3)
handler.setFormatter(logging.Formatter('%(asctime)s %(levelname)s: %(message)s'))
logger.addHandler(handler)

app = Flask(__name__)
app.config['SECRET_KEY'] = 'sLwy2mJaqtEoEb78h_nCeqSPNlIL0zZjcPfHsYNjUz0'
socketio = SocketIO(app, async_mode='threading')
login_manager = LoginManager(app)
executor = ThreadPoolExecutor(max_workers=4)
app.config['DATABASE_URL'] = 'postgresql://dockeradmin:password@10.0.12.241/docker_manager'

# Use a consistent Fernet key for encryption and decryption
fernet_key = b'V8DqheGgw7WBQLTD-4GBOBKRZLh1b9bfqDzHVMjDTUA='
if not fernet_key:
    raise ValueError('Fernet key not found in environment variables')
fernet = Fernet(fernet_key)

app.config['DESTINATION_REPOS'] = {
    'prod': '10.0.12.241:5005',
    'alpha': 'alpha_repo_url',
    'beta': '10.0.12.241:5006',
    'uat': 'sixdee-quay-openshift-operators.apps.ocplab.6d.local',
    'ppd': 'ppd_repo_url'
}  # Set the destination repository URLs for each tag

class User(UserMixin):
    pass

class LoginForm(FlaskForm):
    username = StringField('Username', validators=[DataRequired()])
    password = PasswordField('Password', validators=[DataRequired()])
    submit = SubmitField('Login')

@login_manager.user_loader
def load_user(user_id):
    user = User()
    user.id = user_id
    return user

@login_manager.unauthorized_handler
def unauthorized():
    flash('Please log in to access this page.', 'warning')
    return redirect(url_for('login'))

def get_db_connection():
    logger.info("Establishing database connection")
    try:
        conn = psycopg2.connect(app.config['DATABASE_URL'])
        logger.info("Database connection established")
        return conn
    except Exception as e:
        logger.error(f"Failed to establish database connection: {str(e)}")
        raise

# Establish Docker client
client = docker.from_env()

def refresh_aws_config():
    try:
        # Set the AWS CLI configuration
        subprocess.run(["aws", "configure", "set", "aws_access_key_id", os.environ["AWS_ACCESS_KEY_ID"]], check=True)
        subprocess.run(["aws", "configure", "set", "aws_secret_access_key", os.environ["AWS_SECRET_ACCESS_KEY"]], check=True)
        subprocess.run(["aws", "configure", "set", "default.region", os.environ["AWS_DEFAULT_REGION"]], check=True)
        logger.info("AWS CLI configuration refreshed")
    except subprocess.CalledProcessError as e:
        logger.error(f"Error refreshing AWS CLI configuration: {str(e)}")

# Create a background scheduler
scheduler = BackgroundScheduler()

# Schedule the AWS CLI configuration refresh task to run every 30 minutes
scheduler.add_job(refresh_aws_config, 'interval', minutes=30)

# Start the scheduler
scheduler.start()

def repo_login(repo_url, username=None, password=None):
    if "amazonaws.com" in repo_url:
        try:
            ecr_registry = repo_url.split('/')[0]
            aws_region = ecr_registry.split('.')[3]
            login_command = f"aws ecr get-login-password --region {aws_region} | docker login --username AWS --password-stdin {ecr_registry}"
            subprocess.run(login_command, shell=True, check=True)
            logger.info(f"Docker client authenticated with AWS ECR: {repo_url}")
        except subprocess.CalledProcessError as e:
            logger.error(f"Error authenticating Docker client with AWS ECR: {str(e)}")
            raise Exception(f"Failed to authenticate with AWS ECR: {repo_url}")
    else:
        credentials = get_credentials(repo_url)
        if credentials:
            username = credentials['username']
            password = credentials['password']
        else:
            logger.error(f"No credentials provided or stored for repository: {repo_url}")
            raise Exception(f"Credentials required for repository: {repo_url}")

        # Perform login to the Docker repository with the provided or retrieved credentials
        try:
            login_command = f"docker login -u {username} -p '{password}' {repo_url}"
            subprocess.run(login_command, shell=True, check=True)
            logger.info(f"Docker client authenticated with {repo_url}")
        except subprocess.CalledProcessError as e:
            logger.error(f"Error during Docker login for repository {repo_url}: {str(e)}")
            raise Exception(f"Failed to authenticate with repository: {repo_url}")

def background_transfer(image_paths, destination_tag):
    logger.info(f"Starting background transfer for {len(image_paths)} images")
    source_repo_urls = set()
    submitted_image_paths = set()
    destination_repo_url = app.config['DESTINATION_REPOS'].get(destination_tag)

    if destination_repo_url:
        destination_credentials = get_credentials(destination_repo_url)
        if destination_credentials:
            destination_username = destination_credentials['username']
            destination_password = destination_credentials['password']
        else:
            logger.error(f"No credentials found for destination repository: {destination_repo_url}")
            return

        for image_path in image_paths:
            source_repo_url = image_path.split('/')[0]
            source_repo_urls.add(source_repo_url)

        logger.info(f"Unique source repository URLs: {', '.join(source_repo_urls)}")

        for source_repo_url in source_repo_urls:
            logger.info(f"Processing source repository: {source_repo_url}")
            if "amazonaws.com" in source_repo_url:
                try:
                    ecr_registry = source_repo_url.split('/')[0]
                    aws_region = ecr_registry.split('.')[3]
                    login_command = f"aws ecr get-login-password --region {aws_region} | docker login --username AWS --password-stdin {ecr_registry}"
                    subprocess.run(login_command, shell=True, check=True)
                    logger.info(f"Docker client authenticated with AWS ECR: {source_repo_url}")
                    source_username = None  # Set source_username to None for AWS ECR
                    source_password = None  # Set source_password to None for AWS ECR
                except subprocess.CalledProcessError as e:
                    logger.error(f"Error authenticating Docker client with AWS ECR: {str(e)}")
                    continue
            else:
                source_credentials = get_credentials(source_repo_url)
                if source_credentials:
                    source_username = source_credentials['username']
                    source_password = source_credentials['password']
                else:
                    logger.error(f"No credentials found for source repository: {source_repo_url}")
                    source_username = None  # Set source_username to None if no credentials found
                    source_password = None  # Set source_password to None if no credentials found

                try:
                    login_command = f"docker login -u {source_username} -p {source_password} {source_repo_url}"
                    subprocess.run(login_command, shell=True, check=True)
                    logger.info(f"Docker client authenticated with {source_repo_url}")
                except subprocess.CalledProcessError as e:
                    logger.error(f"Error during Docker login for repository {source_repo_url}: {str(e)}")
                    continue

            for image_path in image_paths:
                if image_path.startswith(source_repo_url) and image_path not in submitted_image_paths:
                    logger.info(f"Submitting transfer task for image: {image_path}")
                    if "amazonaws.com" in destination_repo_url:
                        destination_username = None
                        destination_password = None

                    try:
                        executor.submit(transfer_image, source_repo_url, image_path, destination_repo_url, destination_tag,
                                        source_username, source_password, destination_username, destination_password)
                        logger.info(f"Transfer task submitted for image: {image_path}")
                        submitted_image_paths.add(image_path)  # Add the submitted image path to the set
                    except Exception as e:
                        logger.error(f"Error submitting transfer task for {image_path}: {str(e)}")

    logger.info("All transfer tasks submitted")
    socketio.emit('transfer_complete', include_self=True)
    logger.info("Transfer complete event emitted")

import threading

# Global lock for image removal
image_removal_lock = threading.Lock()

def transfer_image(source_repo_url, image_path, destination_repo_url, destination_tag,
                   source_username, source_password, destination_username, destination_password):
    try:
        logger.info(f"Starting image transfer for {image_path}")

        # Authenticate with the source repository
        if "amazonaws.com" in source_repo_url:
            ecr_registry = source_repo_url.split('/')[0]
            aws_region = ecr_registry.split('.')[3]
            login_command = f"aws ecr get-login-password --region {aws_region} | docker login --username AWS --password-stdin {ecr_registry}"
            subprocess.run(login_command, shell=True, check=True)
            logger.info(f"Docker client authenticated with AWS ECR: {source_repo_url}")
        else:
            repo_login(source_repo_url, source_username, source_password)
            logger.info(f"Authenticated with source repository: {source_repo_url}")

        repo_login(destination_repo_url, destination_username, destination_password)
        logger.info(f"Authenticated with destination repository: {destination_repo_url}")

        image_name = image_path.split('/')[-1]
        timestamp = datetime.now().strftime("%Y%m%d%H%M%S")
        log_file = f"image_logs/{image_name}-{timestamp}.log"
        log_handler = logging.FileHandler(log_file)
        logger.addHandler(log_handler)

        # Extract the image path without the source repository URL
        image_path_without_repo = '/'.join(image_path.split('/')[1:])

        # Check if the image tag contains any environment mention
        image_tag = image_path_without_repo.split(':')[-1]
        env_mentions = ['prod', 'beta', 'uat', 'qa']
        for env in env_mentions:
            if env in image_tag:
                # Replace the environment mention with the destination tag
                modified_image_tag = image_tag.replace(env, destination_tag)
                image_path_without_repo = image_path_without_repo.replace(image_tag, modified_image_tag)
                break

        # Generate the destination image path by combining the destination repository URL and the modified image path
        destination_image_path = f"{destination_repo_url}/{image_path_without_repo}"

        conn = get_db_connection()
        cur = conn.cursor()

        # Check if the entry already exists
        cur.execute("SELECT id FROM docker_manager WHERE source_path = %s AND destination_path = %s", (image_path, destination_image_path))
        existing_entry = cur.fetchone()

        if existing_entry:
            # Update the existing entry
            cur.execute("UPDATE docker_manager SET status = %s, error = %s, date = %s, log_file = %s WHERE id = %s",
                        ('Initiated', None, datetime.now(), log_file, existing_entry[0]))
        else:
            # Insert a new entry
            cur.execute("INSERT INTO docker_manager (source_path, destination_path, date, status, log_file) VALUES (%s, %s, %s, %s, %s)",
                        (image_path, destination_image_path, datetime.now(), 'Initiated', log_file))

        conn.commit()
        cur.close()
        conn.close()

        socketio.emit('transfer_progress', {'image': destination_image_path, 'status': 'initiated'}, room=image_path)
        logger.info(f"Transfer status updated as 'Initiated' for {image_path}")

        logger.info(f"Pulling image: {image_path}")
        try:
            pull_output = client.api.pull(image_path, stream=True, decode=True)
            for line in pull_output:
                if 'error' in line:
                    error_message = line['error']
                    if 'authorization token has expired' in error_message:
                        logger.warning(f"Authorization token expired for {source_repo_url}. Reauthenticating...")
                        if "amazonaws.com" in source_repo_url:
                            ecr_registry = source_repo_url.split('/')[0]
                            aws_region = ecr_registry.split('.')[3]
                            login_command = f"aws ecr get-login-password --region {aws_region} | docker login --username AWS --password-stdin {ecr_registry}"
                            subprocess.run(login_command, shell=True, check=True)
                            logger.info(f"Reauthenticated with AWS ECR: {source_repo_url}")
                        else:
                            repo_login(source_repo_url, source_username, source_password)
                            logger.info(f"Reauthenticated with source repository: {source_repo_url}")
                        pull_output = client.api.pull(image_path, stream=True, decode=True)
                        break
                    else:
                        logger.error(f"Error while pulling image: {error_message}")
                        raise Exception(error_message)
                else:
                    logger.debug(f"Pull output: {line}")
            logger.info(f"Image pulled successfully: {image_path}")
        except Exception as e:
            logger.error(f"Error while pulling image: {str(e)}")
            raise e

        update_transfer_status(image_path, 'Image Pulled', destination_image_path)
        logger.info(f"Transfer status updated as 'Image Pulled' for {image_path}")

        logger.info(f"Tagging image as: {destination_image_path}")
        client.api.tag(image_path, destination_image_path)
        update_transfer_status(image_path, 'Image Tagged', destination_image_path)
        logger.info(f"Transfer status updated as 'Image Tagged' for {image_path}")

        # Re-authenticate with the destination repository before pushing
        repo_login(destination_repo_url, destination_username, destination_password)
        logger.info(f"Re-authenticated with destination repository: {destination_repo_url}")

        logger.info(f"Pushing image to: {destination_image_path}")
        try:
            push_output = client.api.push(destination_image_path, stream=True, decode=True)
            for line in push_output:
                if 'error' in line:
                    error_message = line['errorDetail']['message']
                    logger.error(f"Error while pushing image: {error_message}")
                    raise Exception(error_message)
                else:
                    logger.debug(f"Push output: {line}")
        except Exception as e:
            logger.error(f"Error while pushing image: {str(e)}")
            raise e

        update_transfer_status(image_path, 'Image Pushed', destination_image_path)
        logger.info(f"Transfer status updated as 'Image Pushed' for {image_path}")

        logger.info(f"Image transfer completed: {destination_image_path}")
        update_transfer_status(image_path, 'Completed', destination_image_path)
        logger.info(f"Transfer status updated as 'Completed' for {image_path}")

        with image_removal_lock:
            # Ensure that the image is only removed once
            if not hasattr(transfer_image, 'source_image_removed'):
                transfer_image.source_image_removed = set()
            if image_path not in transfer_image.source_image_removed:
                logger.info(f"Removing source image: {image_path}")
                try:
                    client.api.remove_image(image_path)
                    logger.info(f"Source image removed: {image_path}")
                    transfer_image.source_image_removed.add(image_path)
                except Exception as e:
                    logger.error(f"Error while removing source image: {str(e)}")

            # Ensure that the tagged image is only removed once
            if not hasattr(transfer_image, 'tagged_image_removed'):
                transfer_image.tagged_image_removed = set()
            if destination_image_path not in transfer_image.tagged_image_removed:
                logger.info(f"Removing tagged image: {destination_image_path}")
                try:
                    client.api.remove_image(destination_image_path)
                    logger.info(f"Tagged image removed: {destination_image_path}")
                    transfer_image.tagged_image_removed.add(destination_image_path)
                except Exception as e:
                    logger.error(f"Error while removing tagged image: {str(e)}")

    except Exception as e:
        logger.error(f"Error during image transfer: {str(e)}")
        update_transfer_status(image_path, 'Failed', destination_image_path, str(e))

    finally:
        logger.removeHandler(log_handler)
        log_handler.close()
        logger.info(f"Image transfer completed for {image_path}")

def update_transfer_status(image_path, status, destination_image_path=None, error=None):
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        if destination_image_path:
            cur.execute("UPDATE docker_manager SET status = %s, error = %s, destination_path = %s WHERE source_path = %s",
                        (status, error, destination_image_path, image_path))
        else:
            cur.execute("UPDATE docker_manager SET status = %s, error = %s WHERE source_path = %s",
                        (status, error, image_path))
        conn.commit()
        cur.close()
        conn.close()

        if status in ['Completed', 'Failed']:
            socketio.emit('transfer_progress', {'image': destination_image_path or image_path, 'status': status}, room=image_path)
    except Exception as e:
        logger.error(f"Error updating transfer status: {str(e)}")

@app.route('/')
def index():
   if current_user.is_authenticated:
       return render_template('index.html')
   else:
       return redirect(url_for('login'))

@app.route('/login', methods=['GET', 'POST'])
def login():
    form = LoginForm()
    if form.validate_on_submit():
        username = form.username.data
        password = form.password.data
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("SELECT password FROM users WHERE username = %s", (username,))
        result = cur.fetchone()
        cur.close()
        conn.close()
        if result and check_password_hash(result[0], password):
            user = User()
            user.id = username
            login_user(user)
            return redirect(url_for('index'))
        else:
            return render_template('login.html', form=form, error='Invalid username or password')
    return render_template('login.html', form=form)

@app.route('/logout')
@login_required
def logout():
   logout_user()
   session.clear()  # Clear the session data
   return redirect(url_for('login'))

@app.route('/register', methods=['GET', 'POST'])
def register():
   if not current_user.is_authenticated or not is_admin(current_user.id):
       return "Access Denied", 403

   if request.method == 'POST':
       username = request.form['username']
       password = request.form['password']
       conn = get_db_connection()
       cur = conn.cursor()
       cur.execute("SELECT * FROM users WHERE username = %s", (username,))
       existing_user = cur.fetchone()
       if existing_user:
           cur.close()
           conn.close()
           return render_template('register.html', error='Username already exists')
       else:
           hashed_password = generate_password_hash(password)
           cur.execute("INSERT INTO users (username, password, is_admin) VALUES (%s, %s, %s)", (username, hashed_password, False))
           conn.commit()
           cur.close()
           conn.close()
           return redirect(url_for('manage_users'))
   else:
       return render_template('register.html')

@app.route('/admin')
@login_required
def admin():
   if not is_admin(current_user.id):
       return "Access Denied", 403

   return render_template('admin.html')

@app.route('/transfer', methods=['POST'])
@login_required
def transfer_images():
   destination_tag = request.form.get('destination_tag')

   if 'image_file' in request.files:
       image_file = request.files['image_file']
       if image_file:
           image_paths = image_file.read().decode('utf-8').splitlines()
           executor.submit(background_transfer, image_paths, destination_tag)
           return jsonify({'message': 'Image transfer process started.'}), 202
   return jsonify({'error': 'No image file provided.'}), 400

@app.route('/transfer_single', methods=['POST'])
@login_required
def transfer_single_image():
    image_path = request.form.get('image_path')
    destination_tag = request.form.get('destination_tag')
    force_push = request.form.get('force_push')

    if image_path and destination_tag:
        source_repo_url = image_path.split('/')[0]
        destination_repo_url = app.config['DESTINATION_REPOS'].get(destination_tag)

        if destination_repo_url:
            source_username = None
            source_password = None
            destination_username = None
            destination_password = None

            if "amazonaws.com" not in source_repo_url:
                source_credentials = get_credentials(source_repo_url)
                if source_credentials:
                    source_username = source_credentials['username']
                    source_password = source_credentials['password']
                else:
                    logger.error(f"No credentials found for source repository: {source_repo_url}")
                    return jsonify({'error': 'No credentials found for source repository.'}), 400

            if "amazonaws.com" not in destination_repo_url:
                destination_credentials = get_credentials(destination_repo_url)
                if destination_credentials:
                    destination_username = destination_credentials['username']
                    destination_password = destination_credentials['password']
                else:
                    logger.error(f"No credentials found for destination repository: {destination_repo_url}")
                    return jsonify({'error': 'No credentials found for destination repository.'}), 400

            # Extract the image path without the source repository URL
            image_path_without_repo = '/'.join(image_path.split('/')[1:])

            # Check if the image tag contains any environment mention
            image_tag = image_path_without_repo.split(':')[-1]
            env_mentions = ['prod', 'beta', 'uat', 'qa']
            for env in env_mentions:
                if env in image_tag:
                    # Replace the environment mention with the destination tag
                    modified_image_tag = image_tag.replace(env, destination_tag)
                    image_path_without_repo = image_path_without_repo.replace(image_tag, modified_image_tag)
                    break

            # Generate the destination image path by combining the destination repository URL and the modified image path
            destination_image_path = f"{destination_repo_url}/{image_path_without_repo}"

            conn = get_db_connection()
            cur = conn.cursor()
            cur.execute("SELECT status FROM docker_manager WHERE destination_path = %s", (destination_image_path,))
            existing_status = cur.fetchone()
            if existing_status:
                if existing_status[0] == 'Completed' and force_push != 'true':
                    cur.close()
                    conn.close()
                    return jsonify({'message': f"Image '{destination_image_path}' already exists in the destination repository. Please confirm if you want to force push the image."}), 409
                else:
                    cur.execute("UPDATE docker_manager SET status = %s, error = %s, date = %s WHERE destination_path = %s",
                                ('Initiated', None, datetime.now(), destination_image_path))
            else:
                cur.execute("INSERT INTO docker_manager (source_path, destination_path, date, status, log_file) VALUES (%s, %s, %s, %s, %s)",
                            (image_path, destination_image_path, datetime.now(), 'Initiated', ''))
            conn.commit()
            cur.close()
            conn.close()

            executor.submit(transfer_image, source_repo_url, image_path, destination_repo_url, destination_tag,
                            source_username, source_password, destination_username, destination_password)
            return jsonify({'message': 'Image transfer process started.'}), 202
        else:
            return jsonify({'error': 'Invalid destination tag.'}), 400
    return jsonify({'error': 'Missing required parameters.'}), 400

@app.route('/transfer_selected_images', methods=['POST'])
@login_required
def transfer_selected_images():
    data = request.json
    selected_images = data.get('selectedImages', [])

    if not selected_images:
        return jsonify({'error': 'No images selected.'}), 400

    for image_data in selected_images:
        image_path = image_data.get('image')
        destination_tag = image_data.get('destinationTag')
        if image_path and destination_tag:
            source_repo_url = image_path.split('/')[0]
            destination_repo_url = app.config['DESTINATION_REPOS'].get(destination_tag)

            if destination_repo_url:
                source_username = None
                source_password = None
                destination_username = None
                destination_password = None

                if "amazonaws.com" not in source_repo_url:
                    source_credentials = get_credentials(source_repo_url)
                    if source_credentials:
                        source_username = source_credentials['username']
                        source_password = source_credentials['password']
                    else:
                        logger.error(f"No credentials found for source repository: {source_repo_url}")
                        continue

                if "amazonaws.com" not in destination_repo_url:
                    destination_credentials = get_credentials(destination_repo_url)
                    if destination_credentials:
                        destination_username = destination_credentials['username']
                        destination_password = destination_credentials['password']
                    else:
                        logger.error(f"No credentials found for destination repository: {destination_repo_url}")
                        continue

                # Extract the image path without the source repository URL
                image_path_without_repo = '/'.join(image_path.split('/')[1:])

                # Check if the image tag contains any environment mention
                image_tag = image_path_without_repo.split(':')[-1]
                env_mentions = ['prod', 'beta', 'uat', 'qa']
                for env in env_mentions:
                    if env in image_tag:
                        # Replace the environment mention with the destination tag
                        modified_image_tag = image_tag.replace(env, destination_tag)
                        image_path_without_repo = image_path_without_repo.replace(image_tag, modified_image_tag)
                        break

                # Generate the destination image path by combining the destination repository URL and the modified image path
                destination_image_path = f"{destination_repo_url}/{image_path_without_repo}"

                conn = get_db_connection()
                cur = conn.cursor()
                cur.execute("SELECT status FROM docker_manager WHERE destination_path = %s", (destination_image_path,))
                existing_status = cur.fetchone()
                if existing_status:
                    if existing_status[0] == 'Completed':
                        cur.execute("UPDATE docker_manager SET status = %s, error = %s, date = %s WHERE destination_path = %s",
                                    ('Initiated', None, datetime.now(), destination_image_path))
                    else:
                        cur.execute("INSERT INTO docker_manager (source_path, destination_path, date, status, log_file) VALUES (%s, %s, %s, %s, %s)",
                                    (image_path, destination_image_path, datetime.now(), 'Initiated', ''))
                conn.commit()
                cur.close()
                conn.close()

                executor.submit(transfer_image, source_repo_url, image_path, destination_repo_url, destination_tag,
                                source_username, source_password, destination_username, destination_password)

    return jsonify({'message': 'Selected images transfer process started.'}), 202

@app.route('/log/<path:log_file>', methods=['GET'])
@login_required
def get_log(log_file):
   try:
       return send_file(log_file, as_attachment=True)
   except Exception as e:
       logger.error(f"Error retrieving log file: {str(e)}")
       return str(e), 404

@app.route('/status', methods=['GET'])
@login_required
def get_status():
   search_query = request.args.get('search', '')
   page = request.args.get('page', 1, type=int)
   per_page = 15

   try:
       conn = get_db_connection()
       cur = conn.cursor()
       cur.execute("SELECT source_path, destination_path, date, status, log_file, error FROM docker_manager WHERE source_path ILIKE %s ORDER BY date DESC LIMIT %s OFFSET %s",
                   (f'%{search_query}%', per_page, (page - 1) * per_page))
       transfers = cur.fetchall()
       cur.close()
       conn.close()
       return render_template('status.html', transfers=transfers, search_query=search_query, page=page)
   except Exception as e:
       logger.error(f"Error retrieving transfer status: {str(e)}")
       return str(e)

@app.route('/logs')
@login_required
def get_logs():
   log_files = os.listdir('image_logs')
   return render_template('logs.html', log_files=log_files)

def is_admin(user_id):
   conn = get_db_connection()
   cur = conn.cursor()
   cur.execute("SELECT is_admin FROM users WHERE username = %s", (user_id,))
   result = cur.fetchone()
   cur.close()
   conn.close()
   return result and result[0]

@app.route('/manage_users')
@login_required
def manage_users():
   if not is_admin(current_user.id):
       return "Access Denied", 403

   conn = get_db_connection()
   cur = conn.cursor()
   cur.execute("SELECT username, is_admin FROM users")
   users = cur.fetchall()
   cur.close()
   conn.close()
   return render_template('manage_users.html', users=users)

@app.route('/remove_user/<username>', methods=['POST'])
@login_required
def remove_user(username):
   if not is_admin(current_user.id):
       return "Access Denied", 403

   conn = get_db_connection()
   cur = conn.cursor()
   cur.execute("DELETE FROM users WHERE username = %s", (username,))
   conn.commit()
   cur.close()
   conn.close()
   return redirect(url_for('manage_users'))

@app.route('/admin/store_credentials', methods=['GET', 'POST'])
@login_required
def store_credentials():
   if not is_admin(current_user.id):
       return "Access Denied", 403

   if request.method == 'POST':
       repo_url = request.form.get('repo_url')
       username = request.form.get('username')
       password = request.form.get('password')
       if repo_url and username and password:
           encrypted_password = fernet.encrypt(password.encode()).decode()
           conn = get_db_connection()
           cur = conn.cursor()
           cur.execute("INSERT INTO credentials (repo_url, username, password) VALUES (%s, %s, %s)", (repo_url, username, encrypted_password))
           conn.commit()
           cur.close()
           conn.close()
           flash('Credentials stored successfully.', 'success')
           return redirect(url_for('store_credentials'))
       else:
           flash('Missing required parameters.', 'error')
   return render_template('store_credentials.html')

def get_credentials(repo_url):
   logger.info(f"Fetching credentials for URL: {repo_url}")
   conn = get_db_connection()
   cur = conn.cursor()
   try:
       logger.info(f"Executing SQL query: SELECT username, password FROM credentials WHERE repo_url = '{repo_url}'")
       cur.execute("SELECT username, password FROM credentials WHERE repo_url = %s", (repo_url,))
       result = cur.fetchone()
       logger.info(f"Query result: {result}")
       if result:
           username, encrypted_password = result
           try:
               decrypted_password = fernet.decrypt(encrypted_password.encode()).decode()
               logger.info("Credentials found and decrypted successfully")
               return {'username': username, 'password': decrypted_password}
           except Exception as e:
               logger.error(f"Failed to decrypt password for {repo_url}: {str(e)}")
               return None
       else:
           logger.warning(f"No credentials found for repository URL: {repo_url}")
           return None
   except Exception as e:
       logger.error(f"Failed to retrieve credentials for {repo_url}: {str(e)}")
       return None
   finally:
       cur.close()
       conn.close()

@app.route('/fetch_ecr_images', methods=['POST'])
@login_required
def fetch_ecr_images():
    project_name = 'starhub-sg-cmp-int-shcmp'  # Hardcoded project name

    try:
        ecr_client = boto3.client('ecr')
        response = ecr_client.describe_repositories()
        images = {}

        for repo in response['repositories']:
            if project_name in repo['repositoryName']:
                repo_name = repo['repositoryName']
                image_response = ecr_client.list_images(repositoryName=repo_name)
                for image in image_response['imageIds']:
                    image_details = ecr_client.describe_images(repositoryName=repo_name, imageIds=[image])
                    for detail in image_details['imageDetails']:
                        image_tags = [tag for tag in detail.get('imageTags', [])]
                        pushed_at = detail.get('imagePushedAt', None)
                        uri = repo['repositoryUri']

                        if uri not in images:
                            images[uri] = {
                                'uri': uri,
                                'tags': set(),
                                'pushed_at': pushed_at
                            }
                        images[uri]['tags'].update(image_tags)

        # Convert set of tags to list
        images_list = [{
            'uri': img['uri'],
            'tags': list(img['tags']),
            'pushed_at': img['pushed_at']
        } for img in images.values()]

        return jsonify({'images': images_list})
    except Exception as e:
        logger.error(f"Error fetching ECR images: {str(e)}")
        return jsonify({'error': str(e)}), 500

@app.route('/browse_ecr')
@login_required
def browse_ecr():
    return render_template('browse_ecr.html')

@app.route('/dashboard')
@login_required
def dashboard():
    # Fetch data to be displayed on the dashboard
    conn = get_db_connection()
    cur = conn.cursor()

    # Fetch the total number of images transferred
    cur.execute("SELECT COUNT(*) FROM docker_manager")
    total_transfers = cur.fetchone()[0]

    # Fetch the number of successful and failed transfers
    cur.execute("SELECT status, COUNT(*) FROM docker_manager GROUP BY status")
    status_counts = cur.fetchall()
    success_count = 0
    failure_count = 0
    for status, count in status_counts:
        if status == 'Completed':
            success_count = count
        elif status == 'Failed':
            failure_count = count

    # Fetch recent activities
    cur.execute("SELECT source_path, destination_path, status, date FROM docker_manager ORDER BY date DESC LIMIT 5")
    recent_activities = cur.fetchall()

    cur.close()
    conn.close()

    return render_template('dashboard.html', total_transfers=total_transfers, success_count=success_count, failure_count=failure_count, recent_activities=recent_activities)

if __name__ == "__main__":
   socketio.run(app, debug=True, host='0.0.0.0', port=5000)
