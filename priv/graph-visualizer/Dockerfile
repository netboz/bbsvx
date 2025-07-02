# Step 1: Use a Node.js base image
FROM node:16

# Step 2: Set the working directory inside the container
WORKDIR /app

# Step 3: Copy the package.json and package-lock.json
COPY package*.json ./

# Step 4: Install dependencies
RUN npm install

# Step 5: Copy the rest of the application files
COPY . .

# Step 6: Expose the port that the app will run on
EXPOSE 3400

# Step 7: Define the command to run your app
CMD ["node", "server.js"]
