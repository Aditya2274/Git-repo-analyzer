const { ChatGroq } = require("@langchain/groq");

async function generateGroqReport(prompt) {

    const model = new ChatGroq({
        apiKey: process.env.GROQ_API_KEY,
        model: process.env.GROQ_MODEL || "groq/compound-mini",
        temperature: 0.5,
    });

    const response = await model.invoke(prompt);

    return response.content.trim();
}

module.exports = {
    generateGroqReport
};