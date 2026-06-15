#exact match before we move onto semantic matching 
import os
import pandas as pd
from sqlalchemy import create_engine, text
from dotenv import load_dotenv
import spacy
from spacy.matcher import PhraseMatcher
import matplotlib.pyplot as plt

load_dotenv()
engine = create_engine(os.environ["DATABASE_URL"])
df = pd.read_sql("SELECT job_id, job_description, job_requirements FROM jobs", engine)

#combine job_description and job_requirement for easier extraction and remove tags
df['text'] = ( df['job_description'].fillna('') + ' ' +  df['job_requirements'].fillna(''))
df['text'] = df['text'].str.replace(r"<[^>]+>", " ", regex=True)

print(df.head())

#load lexicon/skill dict
with open('skills/skills_dict.txt', encoding='utf8') as s:
    skills = [line.strip() for line in s if line.strip() and not line.startswith('#')]

#using spacy matcher to collect (job_id, skill) as a pair
nlp = spacy.blank("en")
patterns = [nlp.make_doc(skill) for skill in skills] #pattern docs
matcher = PhraseMatcher(nlp.vocab, attr = 'LOWER') #not hardcoding patterns so using phraseMatcher as oppose to matcher
matcher.add('SKILL', patterns) 

#matching pattern docs against jobs docs
#matcher(doc) creates a list of tuples (match_id, start, end). Get rid of match_id only care about span
rows = []
for job_id, doc in zip(df["job_id"], nlp.pipe(df["text"])): 
    found = {span.text.lower() for span in matcher(doc, as_spans=True)}
    #convert to set tho for dedup
    rows += [{"job_id": job_id, "skill": s} for s in found]

pairs = pd.DataFrame(rows).drop_duplicates()
print(f"extracted {len(pairs)} job-skill pairs across {pairs['job_id'].nunique()} jobs")


#dealing with upsert logic 
with engine.begin() as conn:
    conn.execute(
        text("""
            INSERT INTO job_skills (job_id, skill)
            VALUES (:job_id, :skill)
            ON CONFLICT (job_id, skill) DO NOTHING
        """),
        pairs.to_dict("records"),
    )

#coverage check (the TODO from EDA): what fraction of jobs matched >=1 skill?
covered = pairs["job_id"].nunique()
total = len(df)
print(f"coverage: {covered}/{total} jobs matched at least one skill ({100*covered/total:.1f}%)")
#run 1:86.6% is sufficient. 

#hiring volume by skill
df_skills = pd.read_sql('SELECT * FROM job_skills', engine)
print(df_skills.shape)

df_skills['skill'].value_counts().head(20).plot.barh(
    figsize=(10, 6),
    title='Postings by Skill',
    xlabel='Number of postings',
    ylabel='Skill',
    color='steelblue'
).invert_yaxis()   
# biggest bar on top. too many skills so only taking top 20

plt.tight_layout()
plt.savefig("analysis/figures/postings_by_skill.png", dpi=120)
